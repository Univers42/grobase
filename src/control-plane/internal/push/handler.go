package push

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
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
		if !serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
			return
		}
		next(w, r)
	}
}

func (rt *routes) register(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	sub, err := rt.svc.Register(r.Context(), tenantID, req)
	if rt.handleErr(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, sub)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.List(r.Context(), r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// revoke, send and handleErr live in handler_send.go.
