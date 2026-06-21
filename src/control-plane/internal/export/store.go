/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store.go                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:47 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:50 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// Package export implements per-tenant DATA EXPORT — a PORTABLE bundle of ONE
// tenant's data for GDPR Art. 20 data portability (Track-D D4.3).
//
// It builds on B6 backup's data-SCOPING (internal/backup + internal/erase), but
// the OUTPUT is different in kind: B6 produces a restore-oriented COPY artifact
// (replayed back into the SAME platform); D4.3 produces a PORTABLE bundle — a
// single self-describing JSON document (per-table rows + a manifest carrying the
// table list, per-table row counts, and a sha256 of the data) the tenant can
// take to ANOTHER system. No COPY-format opacity, no restore lifecycle.
//
// SCOPING (strictly ONE tenant, reusing the D4.4 erase resolution):
//
//	schema_per_tenant => the tenant's OWN schema (tenants.TenantSchema(id)); every
//	                     BASE TABLE in it, all rows.
//	shared_rls        => the shared data tables (every public table carrying a
//	                     tenant_id column, minus the control-plane bookkeeping
//	                     set), each filtered WHERE tenant_id = $1. NEVER a bare
//	                     SELECT * over a shared table — that would leak other
//	                     tenants' rows; tenant_id is bound per query, so tenant B's
//	                     rows in the same shared table are never read.
//
// db_per_tenant (needs a DSN resolver, B6b-style) and tenant_owned (external DB)
// are DEFERRED and rejected 400 [ErrIsolationDeferred].
//
// The whole surface is flag-gated by TENANT_EXPORT_ENABLED (default OFF); when
// off, main.go never mounts the routes, so nothing in this package ever runs and
// the table stays empty = byte-parity baseline (same story as B6 / D3 / D4.4).
package export

import (
	"fmt"
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/backup"
)

// ArtifactStore is re-used verbatim from B6 (internal/backup). An export bundle
// is just another artifact (different prefix), so the SAME storage abstraction —
// LocalFileStore default (no MinIO container needed for the gate), MinIO in
// production — backs both. Re-using the interface (not re-implementing it) keeps
// ONE storage code path and ONE SigV4 implementation across backup + export.
type ArtifactStore = backup.ArtifactStore

// NewStoreFromEnv selects the artifact backend for EXPORTS, mirroring
// backup.NewStoreFromEnv but with export-specific knobs so a deployment can land
// exports in a different bucket/dir than restore backups:
//
//	MinIO   when MINIO_ENDPOINT + MINIO_ROOT_USER are set (prefix "exports/").
//	local   otherwise, rooted at $EXPORT_DATA_DIR (default /var/lib/baas-exports).
//
// It reuses backup's exported store constructors (NewMinIOStore / NewLocalFileStore)
// rather than duplicating the storage code — the only difference is the prefix /
// dir, which is the whole point of a separate selector.
func NewStoreFromEnv() (ArtifactStore, error) {
	if ep := os.Getenv("MINIO_ENDPOINT"); ep != "" && os.Getenv("MINIO_ROOT_USER") != "" {
		return backup.NewMinIOStore(ep, os.Getenv("MINIO_ROOT_USER"), os.Getenv("MINIO_ROOT_PASSWORD"), "exports/")
	}
	dir := os.Getenv("EXPORT_DATA_DIR")
	if dir == "" {
		dir = "/var/lib/baas-exports"
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("export: create local artifact dir %q: %w", dir, err)
	}
	return backup.NewLocalFileStore(dir), nil
}
