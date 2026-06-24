/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   shared_erase.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:11 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:13 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package erase

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// deleteSharedRows removes ONLY the caller tenant's rows from the shared data
// tables — every table in the public schema that carries a tenant_id column,
// EXCLUDING the control-plane bookkeeping tables (the tenants registry, its keys,
// and the per-tenant ledgers themselves, which the audit/receipt trail relies
// on). NEVER a TRUNCATE: that would wipe every tenant's rows. tenant_id is bound
// per DELETE, so tenant B's rows in the same shared table are untouched.
func deleteSharedRows(ctx context.Context, tx pgx.Tx, tenantID string) (int64, error) {
	tables, err := enumerateTables(ctx, tx, `
		SELECT c.table_name
		  FROM information_schema.columns c
		 WHERE c.table_schema = 'public'
		   AND c.column_name = 'tenant_id'
		   AND c.table_name NOT IN (
		         'tenants','tenant_api_keys','tenant_databases','tenant_usage',
		         'tenant_billing','tenant_backups','tenant_audit_log',
		         'erasure_receipts','schema_migrations')
		 ORDER BY c.table_name`)
	if err != nil {
		return 0, fmt.Errorf("erase: enumerate shared tables: %w", err)
	}
	var total int64
	for _, tbl := range tables {
		qualified := pgx.Identifier{"public", tbl}.Sanitize()
		tag, err := tx.Exec(ctx,
			fmt.Sprintf(`DELETE FROM %s WHERE tenant_id = $1`, qualified), tenantID)
		if err != nil {
			return 0, fmt.Errorf("erase: delete from %s: %w", qualified, err)
		}
		total += tag.RowsAffected()
	}
	return total, nil
}

// revokeKeys revokes AND deletes every API key for the tenant so no credential
// authenticates after the erase. tenant_id is the tenant slug carried by the
// /v1/tenants/{id} path; tenant_api_keys.tenant_id is the tenant UUID, so the
// DELETE joins through public.tenants on slug. Returns the count deleted.
func revokeKeys(ctx context.Context, tx pgx.Tx, tenantSlug string) (int64, error) {
	tag, err := tx.Exec(ctx, `
		DELETE FROM public.tenant_api_keys k
		 USING public.tenants t
		 WHERE k.tenant_id = t.id AND t.slug = $1`, tenantSlug)
	if err != nil {
		return 0, fmt.Errorf("erase: delete api keys: %w", err)
	}
	return tag.RowsAffected(), nil
}
