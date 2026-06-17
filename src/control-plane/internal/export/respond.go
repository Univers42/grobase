package export

import (
	"context"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// streamBundle writes the bundle to w with the portable content type, mapping
// the service errors. Shared by the admin + self download routes.
func (rt *routes) streamBundle(w http.ResponseWriter, ctx context.Context, tenantID, exportID string) {
	// Set the header BEFORE writing the body; on a pre-stream error map to JSON.
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", "attachment; filename=\"export-"+exportID+".json\"")
	if err := rt.svc.Download(ctx, tenantID, exportID, w); err != nil {
		// If nothing has been written yet (the owner check / status check fail
		// before any byte), the status line is still settable.
		switch {
		case errors.Is(err, ErrNotFound):
			shared.WriteError(w, http.StatusNotFound, "not_found", "export not found")
		default:
			shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
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
		shared.WriteError(w, http.StatusBadRequest, "isolation_unsupported", ErrIsolationDeferred.Error())
	case errors.Is(err, ErrNoMount):
		shared.WriteError(w, http.StatusNotFound, "not_found", ErrNoMount.Error())
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "export not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
