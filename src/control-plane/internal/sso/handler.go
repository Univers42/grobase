package sso

import (
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers the SSO routes onto the shared mux (Track-D D2a). The caller
// mounts this ONLY when SSO_ENABLED is truthy (the parity gate), exactly like
// passkeys.Mount / compliance.Mount / audit.Mount. When OFF, none of these routes
// exist and a request 404s — byte-identical to today, the proven-parity state.
//
// Routes:
//
//	POST /v1/auth/sso/begin                  {connection_id}|{email} -> {authorize_url, state}
//	GET  /v1/auth/sso/callback?state&code    -> {access_token, ...} (a session JWT)
//	POST /v1/auth/sso/callback               {state, code}          -> {access_token, ...}
//	POST /v1/tenants/{id}/sso/connections    (service token) register an IdP connection
//	GET  /v1/tenants/{id}/sso/connections    (service token) list a tenant's connections
//
// AUTHZ:
//   - begin / callback are the PUBLIC login surface: no service token (an end user
//     is signing in). The cryptographic OIDC grant IS the authentication — the
//     single-use state (CSRF) + the verified id_token (sig/iss/aud/exp/nonce) are
//     the proof, so an unauthenticated begin->callback is correct and safe. No
//     session is minted unless the id_token verifies.
//   - the admin register/list routes require a control-plane SERVICE TOKEN OR a
//     matching tenant header (tokenOrSelf), the same shape passkeys/audit use; the
//     tenant_id is taken from the {id} path segment.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/auth/sso/begin", rt.begin)
	mux.HandleFunc("GET /v1/auth/sso/callback", rt.callbackGET)
	mux.HandleFunc("POST /v1/auth/sso/callback", rt.callbackPOST)
	mux.HandleFunc("POST /v1/tenants/{id}/sso/connections", rt.register)
	mux.HandleFunc("GET /v1/tenants/{id}/sso/connections", rt.list)
}

type routes struct {
	svc          *Service
	serviceToken string
}

// ── request bodies ───────────────────────────────────────────────────────────

type beginRequest struct {
	ConnectionID string `json:"connection_id"`
	Email        string `json:"email"`
}

type callbackRequest struct {
	State string `json:"state"`
	Code  string `json:"code"`
}

// ── login handlers (public OIDC surface) ─────────────────────────────────────

func (rt *routes) begin(w http.ResponseWriter, r *http.Request) {
	var req beginRequest
	if err := decodeJSON(r, &req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	if strings.TrimSpace(req.ConnectionID) == "" && strings.TrimSpace(req.Email) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "connection_id or email required")
		return
	}
	res, err := rt.svc.BeginLogin(r.Context(), BeginInput{
		TenantID:     tenantOf(r),
		ConnectionID: req.ConnectionID,
		Email:        req.Email,
	})
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, res)
}

func (rt *routes) callbackGET(w http.ResponseWriter, r *http.Request) {
	rt.finish(w, r, r.URL.Query().Get("state"), r.URL.Query().Get("code"))
}

func (rt *routes) callbackPOST(w http.ResponseWriter, r *http.Request) {
	var req callbackRequest
	if err := decodeJSON(r, &req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	rt.finish(w, r, req.State, req.Code)
}

func (rt *routes) finish(w http.ResponseWriter, r *http.Request, state, code string) {
	session, err := rt.svc.FinishLogin(r.Context(), state, code)
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, session)
}
