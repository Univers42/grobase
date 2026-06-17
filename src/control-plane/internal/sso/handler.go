package sso

import (
	"encoding/json"
	"errors"
	"io"
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

// ── admin handlers (register/list a tenant's connections) ────────────────────

func (rt *routes) register(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	var in RegisterInput
	if err := decodeJSON(r, &in); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	in.TenantID = tenantID
	conn, err := rt.svc.RegisterConnection(r.Context(), in)
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusCreated, conn)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	conns, err := rt.svc.ListConnections(r.Context(), tenantID)
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"connections": conns})
}

// ── helpers ──────────────────────────────────────────────────────────────────

// writeErr maps the service sentinels to HTTP status:
//
//	ErrStateNotFound      -> 401 (missing/expired/replayed state — single-use)
//	ErrTokenRejected      -> 401 (id_token failed verification)
//	ErrConnectionNotFound -> 404
//	ErrConflict           -> 409
//	ErrValidation         -> 400
//	anything else         -> 500
func (rt *routes) writeErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrStateNotFound):
		shared.WriteError(w, http.StatusUnauthorized, "state_rejected", ErrStateNotFound.Error())
	case errors.Is(err, ErrTokenRejected):
		shared.WriteError(w, http.StatusUnauthorized, "token_rejected", "id_token verification failed")
	case errors.Is(err, ErrConnectionNotFound):
		shared.WriteError(w, http.StatusNotFound, "connection_not_found", ErrConnectionNotFound.Error())
	case errors.Is(err, ErrConflict):
		shared.WriteError(w, http.StatusConflict, "conflict", ErrConflict.Error())
	case errors.Is(err, ErrValidation):
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}

// tokenOrSelf authorises an admin call (register/list a tenant's IdP connections,
// keyed by the {id} path segment) by either a control-plane service token or a
// tenant-self assertion via X-Baas-Tenant-Id — the same shape
// passkeys.routes.tokenOrSelf / audit use. For an untenanted (empty) deployment a
// bare service token is required (TenantSelfMatch never matches an empty id).
//
// The self arm goes through shared.TenantSelfMatch: when TENANT_HEADER_IDENTITY_HMAC
// is set, a forged X-Baas-Tenant-Id cannot register/list ANOTHER tenant's SSO
// connections on its own (a valid X-Baas-Identity-Auth signature over the asserted
// {id} is required); OFF (default) it is the unchanged `tenantID != "" && header
// == id` check (parity). The service-token (admin) arm never relies on the header.
func (rt *routes) tokenOrSelf(w http.ResponseWriter, r *http.Request, tenantID string) bool {
	if shared.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if shared.TenantSelfMatch(r, rt.serviceToken, tenantID) {
		return true
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"service token or matching tenant header required")
	return false
}

// tenantOf reads the tenant the request acts within (used by the begin path to
// scope an email-domain lookup). Empty for untenanted / single-tenant deployments.
func tenantOf(r *http.Request) string {
	if v := r.Header.Get("X-Baas-Tenant-Id"); v != "" {
		return v
	}
	return r.Header.Get("X-Tenant-Id")
}

// decodeJSON reads a JSON body with a bounded cap.
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 64<<10))
	if err := dec.Decode(v); err != nil {
		if errors.Is(err, io.EOF) {
			return errors.New("empty body")
		}
		return err
	}
	return nil
}
