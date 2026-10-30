/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 14:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 14:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// audit_log retention and erasure (ADR 0022, grobase#83). The rules live in the
// SQL functions of migration 095; this file only decides when to call them.
package gdprsvc

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

const (
	defaultRetentionDays = 365
	// The SQL floor (095 refuses less) and a ceiling that keeps
	// now() - interval inside the timestamp range.
	minRetentionDays = 30
	maxRetentionDays = 36500
	auditPurgeBatch  = 10000
	// Caveat: the purge runs at boot and then every 24 h, so a row can outlive
	// the retention period by up to a day, and an orchestrator that restarts
	// in a loop purges at every start (bounded batches, idempotent).
	auditPurgeEvery = 24 * time.Hour
)

// parseRetentionDays reads AUDIT_LOG_RETENTION_DAYS. Unset is the default and
// 0 disables retention; any other value outside 30..36500, or not an integer,
// also disables it and returns the reason to log. It never stops the binary,
// because the orchestrator carries five other sub-services (C6).
func parseRetentionDays(raw string) (int, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return defaultRetentionDays, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("AUDIT_LOG_RETENTION_DAYS=%q is not an integer; audit_log retention disabled", raw)
	}
	if n != 0 && (n < minRetentionDays || n > maxRetentionDays) {
		return 0, fmt.Errorf("AUDIT_LOG_RETENTION_DAYS=%d is outside %d..%d (0 disables); audit_log retention disabled",
			n, minRetentionDays, maxRetentionDays)
	}
	return n, nil
}

// eraseAudit anonymises the user's audit_log rows. gdpr user ids are TEXT and
// actor_id is UUID: an id that does not parse can own no audit row, so it is
// skipped, never an error that would stop the request completing (C3). A
// parsed id is sent canonical, because Postgres refuses the urn:uuid: form.
func (s *Service) eraseAudit(ctx context.Context, userID string) error {
	actor, err := uuid.Parse(userID)
	if err != nil {
		s.log.Warn("audit_log erase skipped: user_id is not a UUID")
		return nil
	}
	n, err := s.store.eraseAuditActor(ctx, actor.String())
	if err != nil {
		return fmt.Errorf("audit_log erase: %w", err)
	}
	s.log.Info("audit_log rows anonymised", "rows", n)
	return nil
}

// Run purges audit_log at boot and every auditPurgeEvery until ctx is
// cancelled; with retention disabled it only parks.
func (s *Service) Run(ctx context.Context) {
	if s.retentionErr != nil {
		s.log.Error("audit_log retention", "err", s.retentionErr)
	}
	if s.retentionDays == 0 {
		<-ctx.Done()
		return
	}
	t := time.NewTicker(auditPurgeEvery)
	defer t.Stop()
	for {
		s.purgeAudit(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// purgeAudit deletes expired rows a batch at a time until a batch comes back
// short, checking ctx between batches; it returns the rows deleted.
func (s *Service) purgeAudit(ctx context.Context) int64 {
	var total int64
	for ctx.Err() == nil {
		n, err := s.store.purgeAuditLog(ctx, s.retentionDays, auditPurgeBatch)
		if err != nil {
			s.log.Error("audit_log purge failed", "err", err, "deleted", total)
			return total
		}
		total += n
		if n < auditPurgeBatch {
			break
		}
	}
	s.log.Info("audit_log purge", "deleted", total, "retention_days", s.retentionDays)
	return total
}

func (s *store) eraseAuditActor(ctx context.Context, userID string) (int64, error) {
	var n int64
	err := s.pg.AdminQueryRow(ctx, `SELECT public.audit_log_erase_actor($1::uuid)`, userID).Scan(&n)
	return n, err
}

func (s *store) purgeAuditLog(ctx context.Context, days, batch int) (int64, error) {
	var n int64
	err := s.pg.AdminQueryRow(ctx,
		`SELECT public.audit_log_purge(make_interval(days => $1), $2)`, days, batch).Scan(&n)
	return n, err
}
