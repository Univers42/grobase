package export

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// keyResolver is the seam the self-serve routes use to resolve a tenant API key
// to its owning tenant. *Service satisfies it (its VerifyKey delegates to the
// single-source tenants verifier). Mirrors backup.keyResolver.
type keyResolver interface {
	VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error)
}

// MountSelfServe registers the self-serve export routes onto the shared mux:
//
//	POST /v1/tenants/me/export              export OWN data        -> 202 {export_id}
//	GET  /v1/tenants/me/exports             list OWN exports       -> 200 [...]
//	GET  /v1/tenants/me/export/{exportId}   download OWN bundle    -> 200 application/json
//
// A caller authenticated AS a tenant via an API key acts on ITS OWN data. There
// is NO path id, so cross-tenant access is impossible by construction — the
// tenant is resolved from the credential and bound into every scoped query.
//
// SECOND FLAG: main.go calls MountSelfServe ONLY when BOTH TENANT_EXPORT_ENABLED
// and TENANT_SELFSERVE_ENABLED are truthy (the tenants Service is the
// key->tenant resolver), exactly as backup narrows its self-serve surface. When
// either is OFF these routes are not registered -> 404 = parity.
//
// Static "me" out-ranks the {id} wildcard (net/http most-specific-pattern
// precedence), so these never collide with the admin .../{id}/... routes.
func MountSelfServe(mux *http.ServeMux, svc *Service, keys keyResolver) {
	ss := &selfRoutes{svc: svc, keys: keys}
	mux.HandleFunc("POST /v1/tenants/me/export", ss.createMine)
	mux.HandleFunc("GET /v1/tenants/me/exports", ss.listMine)
	mux.HandleFunc("GET /v1/tenants/me/export/{exportId}", ss.downloadMine)
}

type selfRoutes struct {
	svc  *Service
	keys keyResolver
}

func (ss *selfRoutes) createMine(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	var req createExportRequest
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
	}
	exportID, err := ss.svc.CreateExport(r.Context(), tenantID, strings.TrimSpace(req.Mount))
	if (&routes{}).handleErr(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, map[string]string{"export_id": exportID, "status": "pending"})
}

func (ss *selfRoutes) listMine(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	out, err := ss.svc.ListExports(r.Context(), tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (ss *selfRoutes) downloadMine(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	(&routes{}).streamBundle(w, r.Context(), tenantID, r.PathValue("exportId"))
}

// selfAuth resolves the caller's OWN tenant id from its API key (X-API-Key or
// `Authorization: Bearer mbk_...`), mirroring backup.selfRoutes.selfAuth. The
// returned id is the canonical tenant slug every scoped query keys on — a caller
// can therefore only ever act on its OWN tenant's data.
func (ss *selfRoutes) selfAuth(w http.ResponseWriter, r *http.Request) (tenantID string, ok bool) {
	raw := httpx.APIKeyFromRequest(r)
	if raw == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"X-API-Key or Authorization: Bearer <api-key> required")
		return "", false
	}
	out, err := ss.keys.VerifyKey(r.Context(), raw)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return "", false
	}
	if !out.Valid {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_key", "API key is not valid")
		return "", false
	}
	return out.TenantID, true
}
