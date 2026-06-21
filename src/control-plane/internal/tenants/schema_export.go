/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   schema_export.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:59:41 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:59:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package tenants

// TenantSchema is the EXPORTED accessor for the per-tenant schema-name
// derivation. It delegates verbatim to the package-private [tenantSchema] so
// there is exactly ONE implementation of the sanitizer — the one pinned in
// lockstep with the Rust `DatabaseMount::tenant_schema` by
// TestTenantSchemaMatchesRust (provision_test.go).
//
// The per-tenant backup/restore service (internal/backup) MUST derive the same
// schema name a mount was provisioned under; re-implementing the sanitizer in
// another package would risk drift = a cross-tenant restore bug. This thin
// wrapper lets backup call into the single source of truth instead of copying
// it, so the existing shared test vector keeps both call sites honest.
//
// Returns "" if the id sanitizes to empty (the caller must treat that as a
// non-resolvable / invalid tenant id).
func TenantSchema(id string) string { return tenantSchema(id) }
