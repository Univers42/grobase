/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_request.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:48 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:49 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package gdprsvc

import "context"

/* ─────── deletion (admin-scoped) ─────── */

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
	return firstDeletion(rows, errNotFound)
}

func (s *store) updateRequest(ctx context.Context, id, status, adminID string, note *string) (*DeletionRequest, error) {
	rows, err := s.pg.AdminQuery(ctx,
		`UPDATE gdpr.data_deletion_request
		 SET status = $2, processed_by = $3, processed_at = now(), admin_note = $4
		 WHERE id = $1 RETURNING `+deletionCols, id, status, adminID, note)
	if err != nil {
		return nil, err
	}
	return firstDeletion(rows, errNotFound)
}
