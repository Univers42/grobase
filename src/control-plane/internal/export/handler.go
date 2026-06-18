package export

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
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
		if !serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
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
			httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
	}
	exportID, err := rt.svc.CreateExport(r.Context(), id, strings.TrimSpace(req.Mount))
	if rt.handleErr(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, map[string]string{
		"export_id": exportID,
		"status":    "pending",
	})
}

// listExports returns the tenant's export rows, newest first.
func (rt *routes) listExports(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListExports(r.Context(), r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
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
