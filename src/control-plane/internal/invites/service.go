/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   service.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 06:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 06:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package invites

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// rowScanner is the minimal single-row read surface (satisfied by pgx.Row and pgx.Rows).
type rowScanner interface{ Scan(dest ...any) error }

// Service owns generalized invites over the admin (BYPASSRLS) pool; deps injected (no globals).
type Service struct {
	db  *pg.Postgres
	log *slog.Logger
}

// NewService wires the DB pool and a logger.
func NewService(db *pg.Postgres, log *slog.Logger) *Service { return &Service{db: db, log: log} }

// selectInvite is the canonical redacted projection (never the token) of public.invites.
const selectInvite = `
  SELECT id::text, scope_kind, scope_id::text, COALESCE(org_id::text,''), email, role, status,
         invited_by, expires_at::text, created_at::text, accepted_by
    FROM public.invites`

// genToken returns (cleartext, lower-hex sha256(cleartext)) for a fresh 256-bit invite token.
func genToken() (cleartext, tokenHash string, err error) {
	raw := make([]byte, inviteTokenBytes)
	if _, err = rand.Read(raw); err != nil {
		return "", "", err
	}
	cleartext = inviteTokenPrefix + hex.EncodeToString(raw)
	return cleartext, hashToken(cleartext), nil
}

// hashToken computes lower-hex sha256(token) — the indexed equality key (fast hash is correct
// for a high-entropy secret; nothing to brute-force).
func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// scanInvite reads an invites row in the canonical (redacted) column order.
func scanInvite(row rowScanner, inv *Invite) error {
	return row.Scan(&inv.ID, &inv.ScopeKind, &inv.ScopeID, &inv.OrgID, &inv.Email, &inv.Role,
		&inv.Status, &inv.InvitedBy, &inv.ExpiresAt, &inv.CreatedAt, &inv.AcceptedBy)
}
