/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   destroy.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:42:56 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:42:57 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package erase

import (
	"context"
	"fmt"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
	"github.com/jackc/pgx/v5"
)

// destroy performs the scope-appropriate destruction and revokes the keys,
// returning (rows_purged, keys_revoked). The whole destruction runs in ONE
// transaction so it is all-or-nothing: a mid-erase failure leaves the tenant's
// data intact (no half-erased state) and the receipt flips to 'failed'.
func (s *Service) destroy(ctx context.Context, tenantID, scope string) (int64, int64, error) {
	conn, err := s.db.AcquireConn(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer conn.Release()
	tx, err := conn.Begin(ctx)
	if err != nil {
		return 0, 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	rows, err := destroyScope(ctx, tx, tenantID, scope)
	if err != nil {
		return 0, 0, err
	}
	keys, err := revokeKeys(ctx, tx, tenantID)
	if err != nil {
		return 0, 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, 0, fmt.Errorf("erase: commit destruction: %w", err)
	}
	return rows, keys, nil
}

// destroyScope routes the in-transaction destruction by isolation model and
// returns the pre-destruction row total (the receipt's honest rows_purged).
func destroyScope(ctx context.Context, tx pgx.Tx, tenantID, scope string) (int64, error) {
	switch scope {
	case "schema_per_tenant":
		return dropTenantSchema(ctx, tx, tenants.TenantSchema(tenantID))
	case "shared_rls":
		return deleteSharedRows(ctx, tx, tenantID)
	default:
		return 0, ErrUnsupportedScope
	}
}
