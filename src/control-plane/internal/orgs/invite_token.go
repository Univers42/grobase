/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   invite_token.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:06 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:07 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package orgs

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
)

// invite_token.go — the invite token crypto (high-entropy generate + sha256 hash)
// and the redacted-invite scan. See invite.go for the security discipline note.

// generateInviteToken returns (cleartext, lower-hex sha256(cleartext)).
func generateInviteToken() (cleartext, tokenHash string, err error) {
	raw := make([]byte, inviteTokenBytes)
	if _, err = rand.Read(raw); err != nil {
		return "", "", err
	}
	cleartext = inviteTokenPrefix + hex.EncodeToString(raw)
	tokenHash = hashInviteToken(cleartext)
	return cleartext, tokenHash, nil
}

// hashInviteToken computes lower-hex sha256(token) — the SAME transformation the
// gate independently checks via `printf %s "$token" | sha256sum`.
func hashInviteToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func scanInvite(row interface{ Scan(...any) error }, inv *Invite) error {
	return row.Scan(&inv.ID, &inv.OrgID, &inv.Email, &inv.Role, &inv.Status,
		&inv.InvitedBy, &inv.ExpiresAt, &inv.CreatedAt, &inv.AcceptedBy)
}
