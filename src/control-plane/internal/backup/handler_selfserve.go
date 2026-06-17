package backup

import (
	"context"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// keyResolver is the seam the read-only self-serve route uses to resolve a tenant
// API key to its owning tenant. *tenants.Service satisfies it (its exported
// VerifyKey returns tenants.VerifyKeyResponse{Valid, TenantID, ...}); this
// package depends on tenants only at this boundary, and a fake satisfies the seam
// in unit tests with no live key store.
//
// JWT-bearer self-serve is intentionally NOT wired here: tenants.Service exposes
// VerifyKey (exported) but its user->tenant resolver (findForUser) is unexported,
// and B6 does not own the tenants package. The PRIMARY self-serve case — a tenant
// listing its own backups programmatically — is an API-key call, which this seam
// covers fully. JWT-bearer backup listing is a documented deferral (B6b): a user
// can still list backups via an admin token or an issued API key today.
type keyResolver interface {
	VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error)
}

// MountSelfServe registers the READ-ONLY self-serve route
//
//	GET /v1/tenants/me/backups
//
// onto the shared mux. A caller authenticated AS a tenant via an API key lists ITS
// OWN backups. There is NO path id, so cross-tenant access is impossible by
// construction — the tenant is resolved from the credential and bound into an
// RLS-scoped SELECT (defense-in-depth atop the RLS policy on tenant_backups).
//
// SECOND FLAG: main.go calls MountSelfServe ONLY when BOTH TENANT_BACKUP_ENABLED
// and TENANT_BACKUP_SELFSERVE_ENABLED are truthy (the latter narrows the
// self-serve surface exactly as BILLING_ENABLED narrows tenants.MountSelfServe).
// When either is OFF this route is not registered -> 404 = parity.
//
// keys is the credential resolver (the tenants Service); it must be non-nil when
// this route is mounted. The backup Service supplies the RLS-scoped ListBackups.
func MountSelfServe(mux *http.ServeMux, svc *Service, keys keyResolver) {
	ss := &selfRoutes{svc: svc, keys: keys}
	// Static "me" out-ranks the {id} wildcard (net/http most-specific-pattern
	// precedence), so this never collides with the admin GET .../{id}/backups.
	mux.HandleFunc("GET /v1/tenants/me/backups", ss.listMine)
}

type selfRoutes struct {
	svc  *Service
	keys keyResolver
}

// listMine returns the caller's OWN backups. The tenant id is resolved from the
// credential (never the request path), then passed to the same RLS-scoped
// ListBackups the admin route uses — defense-in-depth atop the RLS policy on
// public.tenant_backups (migration 042).
func (ss *selfRoutes) listMine(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	out, err := ss.svc.ListBackups(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// selfAuth resolves the caller's OWN tenant id from its API key (X-API-Key or
// `Authorization: Bearer mbk_...`), mirroring tenants.selfServe.selfAuth's
// API-key arm (selfserve.go:70). On any failure it writes a 401 and returns
// ok=false. The returned id is the canonical tenant slug ListBackups keys on — a
// caller can therefore only ever list its OWN tenant's backups.
func (ss *selfRoutes) selfAuth(w http.ResponseWriter, r *http.Request) (tenantID string, ok bool) {
	raw := shared.APIKeyFromRequest(r)
	if raw == "" {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"X-API-Key or Authorization: Bearer <api-key> required")
		return "", false
	}
	out, err := ss.keys.VerifyKey(r.Context(), raw)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", false
	}
	if !out.Valid {
		shared.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
		return "", false
	}
	return out.TenantID, true
}
