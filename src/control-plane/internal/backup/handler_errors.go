package backup

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// handleBackupErr maps the backup service's sentinel errors to HTTP status codes,
// mirroring tenants.routes.handleLookup. Returns true when an error was written.
//
//	ErrIsolationDeferred -> 400 (shared_rls / tenant_owned are out of MVP scope)
//	ErrNotOwned          -> 404 (backup.tenant_id != request tenant; load-bearing —
//	                            the module slice returns this for an unknown backup
//	                            too, since the lookup binds (id, tenant_id))
//	anything else        -> 500
func (rt *routes) handleBackupErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrIsolationDeferred):
		httpx.WriteError(w, http.StatusBadRequest, "isolation_unsupported",
			"isolation not supported for backup/restore (deferred)")
	case errors.Is(err, ErrNotOwned):
		// 404 (not 403) so the existence of another tenant's backup is not even
		// confirmed to a probing caller — same opacity as a missing row. The
		// module-slice Restore returns ErrNotOwned for BOTH a wrong-tenant backup
		// and an unknown id (the SELECT binds id AND tenant_id), so this one arm
		// covers the whole load-bearing caller==owner contract.
		httpx.WriteError(w, http.StatusNotFound, "not_found", "backup not found")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
