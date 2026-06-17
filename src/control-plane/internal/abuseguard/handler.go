package abuseguard

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// Mount registers the abuse-guard routes onto the shared mux. Caller mounts this
// ONLY when g.Enabled() (the parity gate) — mirrors metering.Mount / backup.Mount.
//
// Routes (all control-plane internal, service-token guarded):
//
//	POST /v1/abuse/admit                   admission check (project_create, …)
//	POST /v1/abuse/suspend                 admin: suspend a tenant
//	POST /v1/abuse/unsuspend               admin: unsuspend a tenant
//	GET  /v1/abuse/state/{tenantId}        admin: read a tenant's safety row
//
// These are internal endpoints the control plane consults (e.g. the provisioner
// calls /v1/abuse/admit before project_create); they are NOT public tenant-facing
// routes, so they require the service token exactly like POST /v1/keys/verify.
func Mount(mux *http.ServeMux, g *Guard) {
	rt := &routes{g: g}
	mux.HandleFunc("POST /v1/abuse/admit", rt.admit)
	mux.HandleFunc("POST /v1/abuse/suspend", rt.suspend)
	mux.HandleFunc("POST /v1/abuse/unsuspend", rt.unsuspend)
	mux.HandleFunc("GET /v1/abuse/state/{tenantId}", rt.state)
}

type routes struct{ g *Guard }

// AdmitRequest is the POST /v1/abuse/admit body.
type AdmitRequest struct {
	Principal string `json:"principal"` // api-key:<uuid> / user:<id>
	TenantID  string `json:"tenant_id"`
	Tier      string `json:"tier"`   // the tenant's plan/tier (for verification gating)
	Action    string `json:"action"` // e.g. "project_create"
}

func (rt *routes) admit(w http.ResponseWriter, r *http.Request) {
	if !rt.authorized(w, r) {
		return
	}
	var req AdmitRequest
	if err := decodeJSON(r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	res, err := rt.g.Admit(r.Context(), req.Principal, req.TenantID, req.Tier, req.Action)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if !res.Admit {
		// 403 carries the deny + the machine reason in the body (the caller acts on
		// admit:false; the status makes it unambiguous over the wire — the
		// load-bearing reject the gate asserts).
		httpx.WriteJSON(w, http.StatusForbidden, res)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

// StateResponse is the GET /v1/abuse/state/{tenantId} body.
type StateResponse struct {
	TenantID      string `json:"tenant_id"`
	EmailVerified bool   `json:"email_verified"`
	PhoneVerified bool   `json:"phone_verified"`
	PayMethod     bool   `json:"pay_method"`
	Suspended     bool   `json:"suspended"`
}

func (rt *routes) state(w http.ResponseWriter, r *http.Request) {
	if !rt.authorized(w, r) {
		return
	}
	tenantID := r.PathValue("tenantId")
	if tenantID == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "tenantId required")
		return
	}
	s, err := rt.g.readSafety(r.Context(), tenantID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, StateResponse{
		TenantID:      tenantID,
		EmailVerified: s.emailVerified,
		PhoneVerified: s.phoneVerified,
		PayMethod:     s.payMethod,
		Suspended:     s.suspended,
	})
}

// authorized requires the control-plane service token (these are internal routes,
// like POST /v1/keys/verify — never public tenant-facing). When the guard has no
// service token configured (g.serviceToken == ""), the routes are still mounted but
// every call is rejected, so an enabled-but-untokened guard cannot be abused.
func (rt *routes) authorized(w http.ResponseWriter, r *http.Request) bool {
	if rt.g.serviceToken != "" && serviceauth.VerifyServiceRequest(r, rt.g.serviceToken) {
		return true
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
	return false
}

// decodeJSON reads a JSON body with a small cap (these are tiny control messages).
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 8<<10))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}
