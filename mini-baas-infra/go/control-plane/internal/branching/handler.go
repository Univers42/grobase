package branching

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers the admin per-tenant DB-branching routes onto the shared mux
// (Track-E DB branching). All require a control-plane service token (mirroring
// backup/export/erase — a branch clones a tenant's schema, a privileged
// control-plane operation), and read the tenant id from the path via
// r.PathValue("id").
//
//	POST   /v1/tenants/{id}/branches               body {name, mount?} -> 201 {id, branch_schema, ...}
//	GET    /v1/tenants/{id}/branches               -> 200 [{id, branch_name, status, row_count, ...}]
//	DELETE /v1/tenants/{id}/branches/{branchId}    -> 204 (schema dropped + ledger row deleted)
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when DB_BRANCHING_ENABLED is
// truthy. When the flag is OFF (the default) Mount is never called, so none of
// these routes are registered and a request 404s — byte-identical to today, the
// exact discipline of backup.Mount / export.Mount / erase.Mount.
//
// Branching is scoped to schema_per_tenant only; shared_rls / db_per_tenant /
// tenant_owned are rejected 400 "isolation not supported for branching (deferred)"
// (ErrIsolationDeferred).
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/tenants/{id}/branches", rt.requireServiceToken(rt.createBranch))
	mux.HandleFunc("GET /v1/tenants/{id}/branches", rt.requireServiceToken(rt.listBranches))
	mux.HandleFunc("DELETE /v1/tenants/{id}/branches/{branchId}", rt.requireServiceToken(rt.dropBranch))
}

type routes struct {
	svc          *Service
	serviceToken string
}

const msgInvalidJSON = "invalid JSON"

// requireServiceToken gates a handler behind the control-plane service token,
// byte-identical to backup/export/erase's.
func (rt *routes) requireServiceToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !shared.VerifyServiceRequest(r, rt.serviceToken) {
			shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

// createBranchRequest is the POST body. name is REQUIRED (the branch label,
// validated to a safe [a-z0-9_] identifier); mount narrows the isolation lookup
// (empty = whole-tenant first mount).
type createBranchRequest struct {
	Name  string `json:"name"`
	Mount string `json:"mount"`
}

// createBranch clones a schema_per_tenant mount into a fresh branch schema and
// records a row in public.tenant_branches. Returns 201 with the branch row. A
// deferred isolation model is rejected 400, an invalid branch name 400, a
// duplicate name 409 — all BEFORE any clone work for the rejects.
func (rt *routes) createBranch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req createBranchRequest
	if r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
			return
		}
	}
	row, err := rt.svc.CreateBranch(r.Context(), id, strings.TrimSpace(req.Mount), req.Name)
	if rt.handleErr(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusCreated, row)
}

// listBranches returns the tenant's branch rows, newest first.
func (rt *routes) listBranches(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListBranches(r.Context(), r.PathValue("id"))
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

// dropBranch drops the {branchId} branch belonging to {id}. The service validates
// (load-bearing) the branch row's tenant_id matches {id} BEFORE dropping anything:
// a mismatch (or unknown id) yields ErrNotFound -> 404, so a caller can never drop
// another tenant's branch even if it guessed the id.
func (rt *routes) dropBranch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	branchID := r.PathValue("branchId")
	if err := rt.svc.DropBranch(r.Context(), id, branchID); err != nil {
		if rt.handleErr(w, err) {
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleErr maps the branching service's sentinel errors to HTTP status codes,
// mirroring export.handleErr / erase.handleErr. Returns true when an error was
// written.
//
//	ErrIsolationDeferred -> 400 (shared_rls / db_per_tenant / tenant_owned out of MVP scope)
//	ErrInvalidBranchName -> 400 (the SQL-identifier injection wall)
//	ErrBranchExists      -> 409 (UNIQUE(tenant_id, branch_name))
//	ErrNoMount           -> 404 (no registered mount to branch)
//	ErrNotFound          -> 404 (branch.tenant_id != request tenant; load-bearing)
//	anything else        -> 500
func (rt *routes) handleErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrIsolationDeferred):
		shared.WriteError(w, http.StatusBadRequest, "isolation_unsupported", ErrIsolationDeferred.Error())
	case errors.Is(err, ErrInvalidBranchName):
		shared.WriteError(w, http.StatusBadRequest, "invalid_branch_name", ErrInvalidBranchName.Error())
	case errors.Is(err, ErrBranchExists):
		shared.WriteError(w, http.StatusConflict, "branch_exists", ErrBranchExists.Error())
	case errors.Is(err, ErrNoMount):
		shared.WriteError(w, http.StatusNotFound, "not_found", ErrNoMount.Error())
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "branch not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
