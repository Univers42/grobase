package export

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// Mount registers the admin per-tenant export routes onto the shared mux
// (Track-D D4.3). All require a control-plane service token (mirroring
// backup.requireServiceToken — an admin export is a privileged control-plane
// operation), and read the tenant id from the path via r.PathValue("id").
//
//	POST /v1/tenants/{id}/export                body {mount?} -> 202 {export_id, status}
//	GET  /v1/tenants/{id}/exports               -> 200 [{id, isolation, row_count, sha256, ...}]
//	GET  /v1/tenants/{id}/export/{exportId}     -> 200 application/json (the portable bundle)
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when TENANT_EXPORT_ENABLED is
// truthy. When the flag is OFF (the default) Mount is never called, so none of
// these routes are registered and a request 404s — byte-identical to today, the
// exact discipline of backup.Mount / audit.Mount / erase.Mount.
//
// Export is scoped to the two tenant-resolvable isolation models
// (schema_per_tenant, shared_rls); db_per_tenant and tenant_owned are rejected
// 400 "isolation not supported for export (deferred)" (ErrIsolationDeferred).
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/tenants/{id}/export", rt.requireServiceToken(rt.createExport))
	mux.HandleFunc("GET /v1/tenants/{id}/exports", rt.requireServiceToken(rt.listExports))
	mux.HandleFunc("GET /v1/tenants/{id}/export/{exportId}", rt.requireServiceToken(rt.download))
}

type routes struct {
	svc          *Service
	serviceToken string
}

const msgInvalidJSON = "invalid JSON"

// requireServiceToken gates a handler behind the control-plane service token,
// byte-identical to backup.routes.requireServiceToken / erase's.
func (rt *routes) requireServiceToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !shared.VerifyServiceRequest(r, rt.serviceToken) {
			shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

// createExportRequest is the optional POST body. An empty body (or omitted
// mount) exports the whole tenant; a named mount narrows the isolation lookup.
type createExportRequest struct {
	Mount string `json:"mount"`
}

// createExport kicks off a portable export of one tenant's data and records a
// row in public.tenant_exports. Returns 202 with the new export id (the extract
// is synchronous in the service — status reaches completed/failed before return —
// but the surface is async-shaped so a future queued backend is a drop-in). A
// deferred isolation model is rejected 400 BEFORE any work.
func (rt *routes) createExport(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req createExportRequest
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
	}
	exportID, err := rt.svc.CreateExport(r.Context(), id, strings.TrimSpace(req.Mount))
	if rt.handleErr(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusAccepted, map[string]string{
		"export_id": exportID,
		"status":    "pending",
	})
}

// listExports returns the tenant's export rows, newest first.
func (rt *routes) listExports(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListExports(r.Context(), r.PathValue("id"))
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// download streams the portable bundle for {exportId} belonging to {id}. The
// service validates (load-bearing) the export row's tenant_id matches {id} BEFORE
// any bytes flow: a mismatch (or unknown id) yields ErrNotFound -> 404, so a
// download of A can never return B's bundle even if a B caller guessed A's id.
func (rt *routes) download(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	exportID := r.PathValue("exportId")
	rt.streamBundle(w, r.Context(), id, exportID)
}

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

// ── self-serve (read + create-own + download-own) ─────────────────────────────

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
func MountSelfServe(mux *http.ServeMux, svc *Service, keys keyResolver) {
	ss := &selfRoutes{svc: svc, keys: keys}
	// Static "me" out-ranks the {id} wildcard (net/http most-specific-pattern
	// precedence), so these never collide with the admin .../{id}/... routes.
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
			shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
	}
	exportID, err := ss.svc.CreateExport(r.Context(), tenantID, strings.TrimSpace(req.Mount))
	if (&routes{}).handleErr(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusAccepted, map[string]string{"export_id": exportID, "status": "pending"})
}

func (ss *selfRoutes) listMine(w http.ResponseWriter, r *http.Request) {
	tenantID, ok := ss.selfAuth(w, r)
	if !ok {
		return
	}
	out, err := ss.svc.ListExports(r.Context(), tenantID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
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
	raw := apiKeyFromRequest(r)
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

// apiKeyFromRequest extracts a tenant API key from X-API-Key or from an
// `Authorization: Bearer mbk_...` header (mirrors backup.apiKeyFromRequest).
func apiKeyFromRequest(r *http.Request) string {
	if k := strings.TrimSpace(r.Header.Get("X-API-Key")); k != "" {
		return k
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if rest, ok := cutBearer(auth); ok && strings.HasPrefix(rest, "mbk_") {
		return rest
	}
	return ""
}

// cutBearer strips a case-insensitive "Bearer " prefix (mirrors backup.cutBearer).
func cutBearer(auth string) (string, bool) {
	const p = "bearer "
	if len(auth) >= len(p) && strings.EqualFold(auth[:len(p)], p) {
		return strings.TrimSpace(auth[len(p):]), true
	}
	return "", false
}
