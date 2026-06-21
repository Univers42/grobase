/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   relay.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:50:12 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:50:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package outboxrelay

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// process locks one event FOR UPDATE SKIP LOCKED inside a transaction, relays it,
// and commits the new status — mirroring OutboxRelayService.process.
func (s *Service) process(ctx context.Context, id string) {
	conn, err := s.pg.AcquireConn(ctx)
	if err != nil {
		s.log.Warn("outbox acquire conn failed", "err", err)
		return
	}
	defer conn.Release()

	tx, err := conn.Begin(ctx)
	if err != nil {
		s.log.Warn("outbox begin failed", "err", err)
		return
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback(ctx)
		}
	}()
	s.commitProcessed(ctx, tx, id, &committed)
}

// commitProcessed runs processTx and commits when it asks to (setting *committed
// so the caller's deferred rollback is a no-op).
func (s *Service) commitProcessed(ctx context.Context, tx pgx.Tx, id string, committed *bool) {
	if !s.processTx(ctx, tx, id, committed) {
		return
	}
	if err := tx.Commit(ctx); err != nil {
		s.log.Warn("outbox commit failed", "id", id, "err", err)
		return
	}
	*committed = true
}

// processTx runs the lock + relay + status update on the active tx. It returns
// true when the caller should commit; false when an error was already logged
// (the deferred rollback handles cleanup) or it committed an already-taken event
// in place (setting *committed).
func (s *Service) processTx(ctx context.Context, tx pgx.Tx, id string, committed *bool) bool {
	sagaCols, err := hasSagaColumns(ctx, tx)
	if err != nil {
		s.log.Warn("outbox saga-column probe failed", "id", id, "err", err)
		return false
	}
	event, ok, err := lockEvent(ctx, tx, id, s.maxAttempts, sagaCols)
	if err != nil {
		s.log.Warn("outbox lock failed", "id", id, "err", err)
		return false
	}
	if !ok {
		if err := tx.Commit(ctx); err == nil {
			*committed = true
		}
		return false
	}
	return s.applyRelay(ctx, tx, event, sagaCols)
}

// applyRelay relays the locked event and records published/failed status on the
// tx. Returns true when the caller should commit, false on a logged error.
func (s *Service) applyRelay(ctx context.Context, tx pgx.Tx, event *outboxEvent, sagaCols bool) bool {
	if relayErr := s.relay(ctx, event); relayErr != nil {
		if err := s.markFailed(ctx, tx, event, relayErr, sagaCols); err != nil {
			s.log.Warn("outbox markFailed failed", "id", event.ID, "err", err)
			return false
		}
	} else if err := markPublished(ctx, tx, event.ID, sagaCols); err != nil {
		s.log.Warn("outbox markPublished failed", "id", event.ID, "err", err)
		return false
	}
	return true
}
