/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/28 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/28 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package appchannels

import (
	"context"
	"errors"
	"log/slog"

	"github.com/jackc/pgx/v5"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// Service owns app-channel persistence over the admin (BYPASSRLS) pool; deps injected.
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool and a logger.
func NewService(db *pg.Postgres, log *slog.Logger) *Service { return &Service{db: db, log: log} }

// Open creates a pending channel from actor to target (idempotent: a second open of the same
// unordered pair returns the existing row, whatever its status). actor==target ⇒ ErrSameTenant.
func (s *Service) Open(ctx context.Context, actor, target string) (Channel, error) {
	if actor == target {
		return Channel{}, ErrSameTenant
	}
	row := s.db.AdminQueryRow(ctx, `
		INSERT INTO public.app_channels (tenant_a, tenant_b, opened_by)
		VALUES ($1, $2, $1)
		ON CONFLICT (least(tenant_a, tenant_b), greatest(tenant_a, tenant_b)) DO NOTHING`+
		returningCols, actor, target)
	var ch Channel
	if err := scanChannel(row, &ch); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return s.findByPair(ctx, actor, target)
		}
		return Channel{}, err
	}
	return ch, nil
}

// Accept flips a pending channel to accepted in one atomic UPDATE — the acceptor MUST be the
// target side (tenant_b), so only the invited app can consent. No matching pending row ⇒ ErrNotFound.
func (s *Service) Accept(ctx context.Context, channelID, actor string) (Channel, error) {
	row := s.db.AdminQueryRow(ctx, `
		UPDATE public.app_channels
		   SET status='accepted', accepted_at=now()
		 WHERE channel_id=$1 AND status='pending' AND tenant_b=$2`+
		returningCols, channelID, actor)
	var ch Channel
	if err := scanChannel(row, &ch); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return Channel{}, ErrNotFound
		}
		return Channel{}, err
	}
	return ch, nil
}
