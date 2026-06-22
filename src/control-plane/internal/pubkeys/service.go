/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 07:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 07:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pubkeys

import (
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// rowScanner is the minimal single-row read surface (satisfied by pgx.Row and pgx.Rows).
type rowScanner interface{ Scan(dest ...any) error }

// Service owns the pubkey registry + the grant-fulfilment seam over the admin (BYPASSRLS)
// pool; dependencies are injected (no globals).
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool and a logger.
func NewService(db *pg.Postgres, log *slog.Logger) *Service { return &Service{db: db, log: log} }

// scanPubkey reads a user_pubkeys row in the canonical column order.
func scanPubkey(row rowScanner, p *Pubkey) error {
	return row.Scan(&p.UserID, &p.OrgID, &p.Ed25519Pub, &p.X25519Pub, &p.V42Address,
		&p.PubkeySig, &p.CreatedAt, &p.RotatedAt)
}
