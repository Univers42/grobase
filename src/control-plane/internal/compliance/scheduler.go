/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   scheduler.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:41:59 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package compliance

import (
	"context"
	"crypto/rand"
	"fmt"
	"log/slog"
	"os"
	"time"
)

// StartScheduler OPTIONALLY runs the collector on a fixed interval in a
// background goroutine. It is a no-op (returns immediately, starting nothing)
// unless SOC2_EVIDENCE_SCHEDULE parses to a positive duration — the DEFAULT
// (unset/empty) is TODAY'S behavior: no ticker, snapshots only on explicit POST
// /v1/compliance/collect.
//
// PARITY: the caller (cmd/tenant-control) only invokes this inside the
// SOC2_EVIDENCE_ENABLED branch, so with the flag OFF this method is never even
// called; and even when called, an empty/invalid SOC2_EVIDENCE_SCHEDULE starts
// no goroutine. The ticker stops cleanly when ctx is cancelled (process
// shutdown), so it leaks nothing.
//
// It does NOT take an initial snapshot on start — the first tick fires after one
// interval — keeping start-up byte-identical to the no-schedule path.
func (s *Service) StartScheduler(ctx context.Context) {
	raw := os.Getenv("SOC2_EVIDENCE_SCHEDULE")
	if raw == "" {
		return
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		slog.Warn("compliance: ignoring invalid SOC2_EVIDENCE_SCHEDULE (want a positive Go duration, e.g. 24h)",
			"value", raw, "err", err)
		return
	}
	slog.Info("compliance: scheduled evidence snapshots enabled", "interval", d.String())
	go s.runSchedule(ctx, d)
}

// runSchedule snapshots on each tick until ctx is cancelled (process shutdown),
// stopping the ticker cleanly so nothing leaks.
func (s *Service) runSchedule(ctx context.Context, d time.Duration) {
	t := time.NewTicker(d)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			sid, _, cerr := s.Collect(ctx)
			if cerr != nil {
				slog.Error("compliance: scheduled snapshot failed", "err", cerr)
				continue
			}
			slog.Info("compliance: scheduled snapshot sealed", "snapshot_id", sid)
		}
	}
}

// newUUID mints a RFC-4122 v4 UUID string from crypto/rand. The control-plane
// module does not vendor github.com/google/uuid (the audit/backup tables use the
// DB-side gen_random_uuid() default); snapshot_id has no DB default, so we mint
// it in Go without adding a dependency. 16 random bytes with the version/variant
// nibbles set is a standard, collision-safe v4: byte 6's high nibble is forced to
// 0x4 (version 4) and byte 8's top two bits to 0b10 (variant 10).
func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}
