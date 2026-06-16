package scim

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers the SCIM 2.0 routes onto the shared mux (Track-D D2b). The
// caller mounts this ONLY when SCIM_ENABLED is truthy (the parity gate), exactly
// like passkeys.Mount / orgs.Mount / compliance.Mount. When OFF, none of these
// routes exist and a request 404s — byte-identical to today (gotrue has no SCIM).
//
// AUTHZ — two distinct walls:
//   - /scim/v2/* (the IdP surface): BEARER token. Authorization: Bearer <token>
//     -> store.VerifyToken -> bind tenant_id (+org_id). A missing/invalid/revoked
//     token => 401. The bearer->tenant binding IS the per-tenant wall: a T1 token
//     can never read/modify a resource provisioned under T2.
//   - POST /v1/tenants/{id}/scim/tokens (the admin surface): control-plane
//     SERVICE TOKEN. Issues a bearer for a tenant; returns the cleartext ONCE.
//
// The static literal /scim/v2/Users out-ranks /scim/v2/Users/{id} (net/http
// most-specific-pattern precedence), so the list/filter and the by-id routes
// never collide.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}

	// Admin (service token): issue / revoke a SCIM bearer for a tenant.
	mux.HandleFunc("POST /v1/tenants/{id}/scim/tokens", rt.issueToken)
	mux.HandleFunc("DELETE /v1/tenants/{id}/scim/tokens/{tokenId}", rt.revokeToken)

	// SCIM IdP surface (bearer token).
	mux.HandleFunc("POST /scim/v2/Users", rt.createUser)
	mux.HandleFunc("GET /scim/v2/Users", rt.listUsers) // ?filter=userName eq "x"
	mux.HandleFunc("GET /scim/v2/Users/{id}", rt.getUser)
	mux.HandleFunc("PUT /scim/v2/Users/{id}", rt.replaceUser)
	mux.HandleFunc("PATCH /scim/v2/Users/{id}", rt.patchUser)
	mux.HandleFunc("DELETE /scim/v2/Users/{id}", rt.deleteUser)
}

type routes struct {
	svc          *Service
	serviceToken string
}

// ── admin (service-token) ────────────────────────────────────────────────────

type issueTokenRequest struct {
	OrgID       string `json:"org_id"`
	Description string `json:"description"`
}

type issueTokenResponse struct {
	ID          string `json:"id"`
	TenantID    string `json:"tenant_id"`
	OrgID       string `json:"org_id,omitempty"`
	Token       string `json:"token"` // PLAINTEXT — returned ONCE
	Description string `json:"description,omitempty"`
}

func (rt *routes) issueToken(w http.ResponseWriter, r *http.Request) {
	if !rt.admin(w, r) {
		return
	}
	tenantID := r.PathValue("id")
	if strings.TrimSpace(tenantID) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "tenant id required")
		return
	}
	var req issueTokenRequest
	if err := decodeJSON(r, &req); err != nil && !errors.Is(err, io.EOF) {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	cleartext, tokenID, err := rt.svc.IssueToken(r.Context(), tenantID, req.OrgID, req.Description)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, issueTokenResponse{
		ID: tokenID, TenantID: tenantID, OrgID: req.OrgID,
		Token: cleartext, Description: req.Description,
	})
}

func (rt *routes) revokeToken(w http.ResponseWriter, r *http.Request) {
	if !rt.admin(w, r) {
		return
	}
	tenantID := r.PathValue("id")
	tokenID := r.PathValue("tokenId")
	if err := rt.svc.RevokeToken(r.Context(), tenantID, tokenID); err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// admin gates the issue/revoke routes on the control-plane service token.
func (rt *routes) admin(w http.ResponseWriter, r *http.Request) bool {
	if shared.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
	return false
}

// ── SCIM IdP surface (bearer) ────────────────────────────────────────────────

// bearer resolves the SCIM bearer token to its tenant/org binding. On any
// failure (missing/invalid/revoked) it writes a SCIM 401 and returns ok=false —
// the load-bearing reject. This IS the per-tenant wall.
func (rt *routes) bearer(w http.ResponseWriter, r *http.Request) (TokenBinding, bool) {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	const prefix = "Bearer "
	if len(auth) <= len(prefix) || !strings.EqualFold(auth[:len(prefix)], prefix) {
		rt.scimErr(w, http.StatusUnauthorized, "Authorization: Bearer <scim-token> required")
		return TokenBinding{}, false
	}
	tok := strings.TrimSpace(auth[len(prefix):])
	b, err := rt.svc.Authorize(r.Context(), tok)
	if err != nil {
		rt.scimErr(w, http.StatusUnauthorized, "invalid or revoked SCIM token")
		return TokenBinding{}, false
	}
	return b, true
}

func (rt *routes) createUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	var in SCIMUser
	if err := decodeJSON(r, &in); err != nil {
		rt.scimErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.TrimSpace(in.UserName) == "" {
		rt.scimErr(w, http.StatusBadRequest, "userName is required")
		return
	}
	out, err := rt.svc.CreateUser(r.Context(), b, in)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusCreated, out)
}

func (rt *routes) getUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.GetUser(r.Context(), b, r.PathValue("id"))
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusOK, out)
}

func (rt *routes) listUsers(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	resources := []SCIMUser{}
	if userName, found := parseUserNameFilter(r.URL.Query().Get("filter")); found {
		u, hit, err := rt.svc.FindByUserName(r.Context(), b, userName)
		if err != nil {
			rt.scimErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if hit {
			resources = append(resources, u)
		}
	}
	rt.writeSCIM(w, http.StatusOK, ListResponse{
		Schemas:      []string{schemaListResponse},
		TotalResults: len(resources),
		StartIndex:   1,
		ItemsPerPage: len(resources),
		Resources:    resources,
	})
}

func (rt *routes) replaceUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	var in SCIMUser
	if err := decodeJSON(r, &in); err != nil {
		rt.scimErr(w, http.StatusBadRequest, err.Error())
		return
	}
	out, err := rt.svc.ReplaceUser(r.Context(), b, r.PathValue("id"), in)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusOK, out)
}

func (rt *routes) patchUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	var p PatchOp
	if err := decodeJSON(r, &p); err != nil {
		rt.scimErr(w, http.StatusBadRequest, err.Error())
		return
	}
	out, err := rt.svc.PatchUser(r.Context(), b, r.PathValue("id"), p)
	if err != nil {
		rt.mapErr(w, err)
		return
	}
	rt.writeSCIM(w, http.StatusOK, out)
}

func (rt *routes) deleteUser(w http.ResponseWriter, r *http.Request) {
	b, ok := rt.bearer(w, r)
	if !ok {
		return
	}
	if err := rt.svc.DeleteUser(r.Context(), b, r.PathValue("id")); err != nil {
		rt.mapErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── helpers ──────────────────────────────────────────────────────────────────

// parseUserNameFilter extracts x from a SCIM filter of the form
//
//	userName eq "x"
//
// (the only filter an IdP needs for the existence check before create). Returns
// found=false for any other/absent filter (an unsupported filter yields an empty
// ListResponse rather than an error, which IdPs tolerate).
func parseUserNameFilter(filter string) (userName string, found bool) {
	f := strings.TrimSpace(filter)
	low := strings.ToLower(f)
	if !strings.HasPrefix(low, "username") {
		return "", false
	}
	rest := strings.TrimSpace(f[len("username"):])
	lowRest := strings.ToLower(rest)
	if !strings.HasPrefix(lowRest, "eq") {
		return "", false
	}
	val := strings.TrimSpace(rest[len("eq"):])
	val = strings.Trim(val, `"`)
	if val == "" {
		return "", false
	}
	return val, true
}

// mapErr maps service errors to SCIM error responses. ErrNotFound => 404 (the
// wall: a cross-tenant id is "not found"). ErrNoOrg => 400. Anything else => 500.
func (rt *routes) mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		rt.scimErr(w, http.StatusNotFound, "resource not found")
	case errors.Is(err, ErrNoOrg):
		rt.scimErr(w, http.StatusBadRequest, "SCIM token is not bound to an org; set org_id when issuing the token")
	default:
		rt.scimErr(w, http.StatusInternalServerError, err.Error())
	}
}

// writeSCIM emits a resource/list with the SCIM content type.
func (rt *routes) writeSCIM(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", contentTypeSCIM)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// scimErr emits a SCIM Error envelope (status as a STRING, per RFC 7644 §3.12).
func (rt *routes) scimErr(w http.ResponseWriter, status int, detail string) {
	w.Header().Set("Content-Type", contentTypeSCIM)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(scimError{
		Schemas: []string{schemaError},
		Detail:  detail,
		Status:  strconv.Itoa(status),
	})
}

// decodeJSON reads a JSON body with a sane size cap (mirrors passkeys.decodeJSON).
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	return dec.Decode(v)
}
