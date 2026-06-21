/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   audit.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:54 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:55 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package erase

import (
	"context"
	"encoding/json"

	"github.com/dlesieur/mini-baas/control-plane/internal/audit"
)

// sealParams groups the audit-receipt inputs for sealReceipt (formerly its
// positional args, 1:1).
type sealParams struct {
	tenantID, requestedBy, scope string
	rows, keys                   int64
}

// sealReceipt appends a D3 audit event recording the erase onto the tenant's
// tamper-evident chain and returns the sealed seq. Best-effort on the seq: the
// destruction already committed, so an audit hiccup must not undo it — but the
// erasure_receipts row still records what happened (audit_seq stays 0 then). The
// receipt payload carries the storage-scope note (object-store deletion is the
// downstream reaper's job; the platform records the intent here).
func (s *Service) sealReceipt(ctx context.Context, p sealParams) int64 {
	payload, _ := json.Marshal(map[string]any{
		"scope":         p.scope,
		"rows_purged":   p.rows,
		"keys_revoked":  p.keys,
		"storage_scope": "object-store deletion is best-effort/downstream; postgres data provably destroyed",
	})
	ev, err := s.audit.Append(ctx, audit.AppendInput{
		TenantID: p.tenantID,
		Actor:    p.requestedBy,
		Action:   "tenant.erase",
		Target:   p.tenantID,
		Payload:  payload,
	})
	if err != nil {
		s.log.Warn("erase: audit receipt append failed (data already destroyed)", "tenant", p.tenantID, "err", err)
		return 0
	}
	return ev.Seq
}
