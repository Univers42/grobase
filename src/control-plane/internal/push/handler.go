package push

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers the admin per-tenant push routes onto the shared mux (Track-E
// push / messaging). All require a control-plane service token (push is a
// privileged control-plane operation, mirroring backup/export/scim), and read
// the tenant id from the path via r.PathValue("id"):
//
//	POST   /v1/tenants/{id}/push/subscriptions        register a subscription -> 201
//	GET    /v1/tenants/{id}/push/subscriptions        list live subscriptions -> 200
//	DELETE /v1/tenants/{id}/push/subscriptions/{subId} revoke a subscription   -> 204
//	POST   /v1/tenants/{id}/push/send                 fan a notification out   -> 200
//
// FLAG-GATED OFF = PARITY: main.go calls Mount ONLY when PUSH_ENABLED is truthy.
// When OFF (the default) Mount is never called, so none of these routes are
// registered and a request 404s — byte-identical to today, the same discipline
// as TENANT_EXPORT_ENABLED / SCIM_ENABLED / TENANT_BACKUP_ENABLED.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/tenants/{id}/push/subscriptions", rt.requireServiceToken(rt.register))
	mux.HandleFunc("GET /v1/tenants/{id}/push/subscriptions", rt.requireServiceToken(rt.list))
	mux.HandleFunc("DELETE /v1/tenants/{id}/push/subscriptions/{subId}", rt.requireServiceToken(rt.revoke))
	mux.HandleFunc("POST /v1/tenants/{id}/push/send", rt.requireServiceToken(rt.send))
}

type routes struct {
	svc          *Service
	serviceToken string
}

const msgInvalidJSON = "invalid JSON"

// requireServiceToken gates a handler behind the control-plane service token,
// byte-identical to export/backup/scim's requireServiceToken.
func (rt *routes) requireServiceToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !shared.VerifyServiceRequest(r, rt.serviceToken) {
			shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

func (rt *routes) register(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	sub, err := rt.svc.Register(r.Context(), tenantID, req)
	if rt.handleErr(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusCreated, sub)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.List(r.Context(), r.PathValue("id"))
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) revoke(w http.ResponseWriter, r *http.Request) {
	err := rt.svc.Revoke(r.Context(), r.PathValue("id"), r.PathValue("subId"))
	if rt.handleErr(w, err) {
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *routes) send(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	var req SendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	res, err := rt.svc.Send(r.Context(), tenantID, req)
	if rt.handleErr(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, res)
}

// handleErr maps the push service's sentinel errors to HTTP status codes.
//
//	ErrValidation    -> 400 (malformed request)
//	ErrBlockedTarget -> 400 (SSRF guard refused the target_url)
//	ErrNotFound      -> 404 (subscription not under the caller's tenant; load-bearing)
//	anything else    -> 500
func (rt *routes) handleErr(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrBlockedTarget):
		shared.WriteError(w, http.StatusBadRequest, "blocked_target", err.Error())
	case errors.Is(err, ErrValidation):
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "push subscription not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
