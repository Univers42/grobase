/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   respond.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:43:36 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:43:38 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package export

import (
	"context"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// streamBundle writes the bundle to w with the portable content type, mapping
// the service errors. Shared by the admin + self download routes. The header is
// set BEFORE the body; a pre-stream error maps to JSON. When the owner / status
// check fails before any byte is written, the status line is still settable.
func (rt *routes) streamBundle(w http.ResponseWriter, ctx context.Context, tenantID, exportID string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", "attachment; filename=\"export-"+exportID+".json\"")
	if err := rt.svc.Download(ctx, tenantID, exportID, w); err != nil {
		switch {
		case errors.Is(err, ErrNotFound):
			httpx.WriteError(w, http.StatusNotFound, "not_found", "export not found")
		default:
			httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		}
	}
}

// handleErr maps the export service's sentinel errors to HTTP status codes,
// mirroring backup.handleBackupErr / erase.handleErr. Returns true when an error
// was written.
//
//	ErrIsolationDeferred -> 400 (db_per_tenant / tenant_owned out of MVP scope)
//	ErrNoMount           -> 404 (no registered mount to export)
//	ErrNotFound          -> 404 (export.tenant_id != request tenant; load-bearing)
//	anything else        -> 500
func (rt *routes) handleErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrIsolationDeferred):
		httpx.WriteError(w, http.StatusBadRequest, "isolation_unsupported", ErrIsolationDeferred.Error())
	case errors.Is(err, ErrNoMount):
		httpx.WriteError(w, http.StatusNotFound, "not_found", ErrNoMount.Error())
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "export not found")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
