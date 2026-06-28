/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package appchannels

import "context"

// rowScanner is the minimal single-row read surface (satisfied by pgx.Row and pgx.Rows).
type rowScanner interface{ Scan(dest ...any) error }

// scanChannel reads one channel row in column order.
func scanChannel(row rowScanner, ch *Channel) error {
	return row.Scan(&ch.ID, &ch.TenantA, &ch.TenantB, &ch.ChannelID,
		&ch.Status, &ch.OpenedBy, &ch.CreatedAt, &ch.AcceptedAt)
}

// findByPair returns the channel for an unordered tenant pair (the idempotent-open fallback).
func (s *Service) findByPair(ctx context.Context, a, b string) (Channel, error) {
	row := s.db.AdminQueryRow(ctx, selectCols+`
		WHERE least(tenant_a, tenant_b)=least($1,$2)
		  AND greatest(tenant_a, tenant_b)=greatest($1,$2)`, a, b)
	var ch Channel
	if err := scanChannel(row, &ch); err != nil {
		return Channel{}, err
	}
	return ch, nil
}

// ListForTenant returns every channel this tenant is an end of, newest first.
func (s *Service) ListForTenant(ctx context.Context, tenant string) ([]Channel, error) {
	rows, err := s.db.AdminQuery(ctx, selectCols+`
		WHERE tenant_a=$1 OR tenant_b=$1 ORDER BY created_at DESC`, tenant)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]Channel, 0)
	for rows.Next() {
		var ch Channel
		if err := scanChannel(rows, &ch); err != nil {
			return nil, err
		}
		out = append(out, ch)
	}
	return out, rows.Err()
}

// AcceptedChannelIDs returns the channel_id of every ACCEPTED channel this tenant is an end of —
// the exact set of xapp:<id> namespaces a realtime token for this tenant may carry.
func (s *Service) AcceptedChannelIDs(ctx context.Context, tenant string) ([]string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT channel_id FROM public.app_channels
		  WHERE (tenant_a=$1 OR tenant_b=$1) AND status='accepted'`, tenant)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]string, 0)
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
