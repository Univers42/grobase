package tenants

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

func (rt *routes) bootstrap(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req BootstrapRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	name := id
	if v := r.URL.Query().Get("name"); v != "" {
		name = v
	}
	out, err := rt.svc.Bootstrap(r.Context(), id, name, req)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, out)
}

func (rt *routes) provision(w http.ResponseWriter, r *http.Request) {
	req, ok := decodeProvision(w, r)
	if !ok {
		return
	}
	// Preferred path: route the legacy declarative request through the new
	// reconcile brain (Compile maps the old shape onto a typed StackSpec).
	if rt.reconciler != nil {
		rt.reconcile(w, r, req)
		return
	}
	// Fallback (no reconciler wired): the original one-shot Provision path.
	out, err := rt.svc.Provision(r.Context(), req)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, out)
}

// decodeProvision caps the body (DoS guard: the payload carries unbounded
// mount/role/key arrays, so reject an oversized request before it exhausts
// memory — the same centralized cap as the standalone seam), then decodes and
// validates it. ok=false means a 400 was written.
func decodeProvision(w http.ResponseWriter, r *http.Request) (ProvisionRequest, bool) {
	r.Body = http.MaxBytesReader(w, r.Body, provision.MaxRequestBodyBytes)
	var req ProvisionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return ProvisionRequest{}, false
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return ProvisionRequest{}, false
	}
	return req, true
}

// reconcile routes a declarative provision request through the reconciler brain.
func (rt *routes) reconcile(w http.ResponseWriter, r *http.Request, req ProvisionRequest) {
	out, err := rt.reconciler.Reconcile(r.Context(), req.Compile())
	switch {
	case errors.Is(err, provision.ErrBusy):
		httpx.WriteError(w, http.StatusConflict, "conflict", err.Error())
	case err != nil:
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	default:
		httpx.WriteJSON(w, provision.HTTPStatus(out.Outcome, out.APIKey != nil), out)
	}
}
