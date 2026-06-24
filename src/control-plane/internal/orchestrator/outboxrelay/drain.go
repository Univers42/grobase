/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   drain.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:49:41 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:49:43 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// tick drains one batch: select candidate ids, refresh the lag gauge, then
// process each. Errors are logged, never fatal (the next tick retries).
func (s *Service) tick(ctx context.Context) {
	ids, ok := s.selectBatch(ctx)
	if !ok {
		return
	}
	s.updateLag(ctx)
	for _, id := range ids {
		s.process(ctx, id)
	}
}

// selectBatch reads the candidate ids for one tick. ok=false means the query or
// scan failed (already logged); the next tick retries.
func (s *Service) selectBatch(ctx context.Context) ([]string, bool) {
	rows, err := s.pg.AdminQuery(ctx,
		`SELECT id::text AS id
		   FROM public.outbox_events
		  WHERE status IN ('pending','failed') AND attempts < $1
		  ORDER BY created_at ASC, id ASC
		  LIMIT $2`, s.maxAttempts, s.batchSize)
	if err != nil {
		s.log.Warn("outbox relay tick failed", "err", err)
		return nil, false
	}
	defer rows.Close()
	return s.scanBatch(rows)
}

// scanBatch collects the id column of a candidate-batch result set; ok=false on
// a scan/rows error (already logged).
func (s *Service) scanBatch(rows pgx.Rows) ([]string, bool) {
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			s.log.Warn("outbox relay scan failed", "err", err)
			return nil, false
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		s.log.Warn("outbox relay rows error", "err", err)
		return nil, false
	}
	return ids, true
}
