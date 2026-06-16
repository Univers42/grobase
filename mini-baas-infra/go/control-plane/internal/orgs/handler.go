package orgs

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// jwtVerifier is the seam the org handlers use to resolve the calling human's
// GoTrue user uuid from a Bearer JWT. *tenants.JWTVerifier satisfies it; a fake
// satisfies it in unit tests. Org authorization is ALWAYS a human (JWT) decision
// — never a service token, never an API key — because an org is a human concept
// above the project.
type jwtVerifier interface {
	Verify(raw string) (tenants.VerifiedIdentity, error)
}

// routes holds the org HTTP dependencies. The org-scoped project route delegates
// to the EXISTING *provision.Reconciler verbatim — adding a capability gate
// BEFORE the call and an org_id stamp AFTER it; the reconcile itself is byte-
// identical to what /v1/provision does today.
type routes struct {
	svc          *Service
	tenantSvc    *tenants.Service
	reconciler   *provision.Reconciler
	jwt          jwtVerifier
	serviceToken string
}

const msgInvalidJSON = "invalid JSON"

// Mount registers /v1/orgs* onto the shared mux. It is the caller's
// responsibility (cmd/tenant-control/main.go) to invoke this ONLY when
// ORG_MODEL_ENABLED is truthy — when the flag is OFF this function is never
// called and the /v1/orgs* routes do not exist (404 = byte-parity with today).
//
// The static literal /v1/orgs/invites/accept out-ranks the /v1/orgs/{orgId}
// wildcard (net/http most-specific-pattern precedence), exactly as
// /v1/tenants/me* out-ranks /v1/tenants/{id}, so the two route sets never collide.
func Mount(mux *http.ServeMux, svc *Service, tenantSvc *tenants.Service,
	reconciler *provision.Reconciler, jwt jwtVerifier, serviceToken string) {
	rt := &routes{svc: svc, tenantSvc: tenantSvc, reconciler: reconciler, jwt: jwt, serviceToken: serviceToken}

	mux.HandleFunc("POST /v1/orgs", rt.createOrg)
	mux.HandleFunc("GET /v1/orgs", rt.listOrgs)

	// Static literal first (precedence): invite acceptance carries no orgId.
	mux.HandleFunc("POST /v1/orgs/invites/accept", rt.acceptInvite)

	mux.HandleFunc("GET /v1/orgs/{orgId}", rt.getOrg)
	mux.HandleFunc("PATCH /v1/orgs/{orgId}", rt.updateOrg)
	mux.HandleFunc("DELETE /v1/orgs/{orgId}", rt.deleteOrg)

	mux.HandleFunc("GET /v1/orgs/{orgId}/members", rt.listMembers)
	mux.HandleFunc("PATCH /v1/orgs/{orgId}/members/{userId}", rt.setMemberRole)
	mux.HandleFunc("DELETE /v1/orgs/{orgId}/members/{userId}", rt.removeMember)

	mux.HandleFunc("POST /v1/orgs/{orgId}/invites", rt.issueInvite)
	mux.HandleFunc("GET /v1/orgs/{orgId}/invites", rt.listInvites)
	mux.HandleFunc("DELETE /v1/orgs/{orgId}/invites/{inviteId}", rt.revokeInvite)

	mux.HandleFunc("POST /v1/orgs/{orgId}/projects", rt.createProject)
	mux.HandleFunc("GET /v1/orgs/{orgId}/projects", rt.listProjects)
	mux.HandleFunc("GET /v1/orgs/{orgId}/usage", rt.usage)
}

// authJWT resolves the calling human's GoTrue user uuid from the Authorization
// Bearer JWT. On any failure it writes 401 and returns ok=false.
func (rt *routes) authJWT(w http.ResponseWriter, r *http.Request) (userID string, ok bool) {
	if rt.jwt == nil {
		shared.WriteError(w, http.StatusNotImplemented, "not_implemented",
			"org API requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		return "", false
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if auth == "" {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "Authorization: Bearer <jwt> required")
		return "", false
	}
	id, err := rt.jwt.Verify(auth)
	if err != nil {
		shared.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
		return "", false
	}
	if id.UserID == "" {
		shared.WriteError(w, http.StatusUnauthorized, "invalid_token", "token missing sub")
		return "", false
	}
	return id.UserID, true
}

// requireCapability is the load-bearing gate: it resolves the caller's role in
// the org and checks the RBAC matrix. A NON-member (no role) → 404 (the org's
// existence is not even confirmed to a probing non-member = cross-org isolation).
// A member lacking the capability → 403 (the load-bearing reject). On success it
// returns the caller's user id + role.
//
// This is a pure control-plane decision — it never consults the data-plane ABAC
// PDP and never touches RequestIdentity or the RLS GUCs.
func (rt *routes) requireCapability(w http.ResponseWriter, r *http.Request, orgID, cap string) (userID string, role Role, ok bool) {
	userID, ok = rt.authJWT(w, r)
	if !ok {
		return "", "", false
	}
	role, member := rt.svc.MemberRole(r.Context(), orgID, userID)
	if !member {
		// Opaque 404: a non-member cannot distinguish "no such org" from "an org
		// you are not in" — cross-org isolation by membership lookup, not by id.
		shared.WriteError(w, http.StatusNotFound, "not_found", "org not found")
		return "", "", false
	}
	if !Can(role, cap) {
		shared.WriteError(w, http.StatusForbidden, "forbidden",
			"your org role ("+string(role)+") may not perform "+cap)
		return "", "", false
	}
	return userID, role, true
}

// ── org CRUD ─────────────────────────────────────────────────────────────────

func (rt *routes) createOrg(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.authJWT(w, r)
	if !ok {
		return
	}
	var req CreateOrgRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	o, err := rt.svc.CreateOrg(r.Context(), req, userID)
	switch {
	case errors.Is(err, ErrConflict):
		shared.WriteError(w, http.StatusConflict, "conflict", "org slug already exists")
	case err != nil:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		shared.WriteJSON(w, http.StatusCreated, o)
	}
}

func (rt *routes) listOrgs(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.authJWT(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.ListOrgsForUser(r.Context(), userID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) getOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgRead); !ok {
		return
	}
	o, err := rt.svc.GetOrg(r.Context(), orgID)
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, o)
}

func (rt *routes) updateOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgUpdate); !ok {
		return
	}
	var req UpdateOrgRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	o, err := rt.svc.UpdateOrg(r.Context(), orgID, req)
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, o)
}

func (rt *routes) deleteOrg(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgDelete); !ok {
		return
	}
	if rt.handleLookup(w, rt.svc.SoftDeleteOrg(r.Context(), orgID)) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}

// ── members ──────────────────────────────────────────────────────────────────

func (rt *routes) listMembers(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgRead); !ok {
		return
	}
	out, err := rt.svc.ListMembers(r.Context(), orgID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) setMemberRole(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	targetUser := r.PathValue("userId")
	_, actorRole, ok := rt.requireCapability(w, r, orgID, CapMemberRoleSet)
	if !ok {
		return
	}
	var req SetRoleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if !validRole(req.Role) {
		shared.WriteError(w, http.StatusBadRequest, "validation_error",
			"role must be one of owner|admin|developer|billing|viewer")
		return
	}
	// admin-vs-owner asymmetry: an admin may not mint/touch an owner.
	currentRole, member := rt.svc.MemberRole(r.Context(), orgID, targetUser)
	if !member {
		shared.WriteError(w, http.StatusNotFound, "not_found", "member not found")
		return
	}
	if !canSetRole(actorRole, Role(req.Role), currentRole) {
		shared.WriteError(w, http.StatusForbidden, "forbidden",
			"an admin may not create or modify an owner; only an owner can")
		return
	}
	err := rt.svc.SetMemberRole(r.Context(), orgID, targetUser, req.Role)
	if errors.Is(err, ErrLastOwner) {
		shared.WriteError(w, http.StatusConflict, "conflict", "cannot demote the last owner")
		return
	}
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]string{"user_id": targetUser, "role": req.Role})
}

func (rt *routes) removeMember(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	targetUser := r.PathValue("userId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapMemberRemove); !ok {
		return
	}
	err := rt.svc.RemoveMember(r.Context(), orgID, targetUser)
	if errors.Is(err, ErrLastOwner) {
		shared.WriteError(w, http.StatusConflict, "conflict", "cannot remove the last owner")
		return
	}
	if rt.handleLookup(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"removed": true})
}

// ── invites ──────────────────────────────────────────────────────────────────

func (rt *routes) issueInvite(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.requireCapability(w, r, orgID, CapMemberInvite)
	if !ok {
		return
	}
	var req InviteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if err := req.Validate(); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	out, err := rt.svc.IssueInvite(r.Context(), orgID, req.Email, req.Role, userID)
	switch {
	case errors.Is(err, ErrConflict):
		shared.WriteError(w, http.StatusConflict, "conflict", "a pending invite already exists for this email")
	case err != nil:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		shared.WriteJSON(w, http.StatusCreated, out)
	}
}

func (rt *routes) listInvites(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapOrgRead); !ok {
		return
	}
	out, err := rt.svc.ListInvites(r.Context(), orgID)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) revokeInvite(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	inviteID := r.PathValue("inviteId")
	if _, _, ok := rt.requireCapability(w, r, orgID, CapMemberInvite); !ok {
		return
	}
	if rt.handleLookup(w, rt.svc.RevokeInvite(r.Context(), orgID, inviteID)) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

// acceptInvite consumes a cleartext invite token. It is authenticated by the
// accepting human's JWT (the token says WHICH org+role; the JWT says WHO) — no
// org capability gate, because the invite IS the authorization to join.
func (rt *routes) acceptInvite(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.authJWT(w, r)
	if !ok {
		return
	}
	var req AcceptInviteRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	if strings.TrimSpace(req.Token) == "" {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", "token is required")
		return
	}
	o, role, err := rt.svc.AcceptInvite(r.Context(), req.Token, userID)
	switch {
	case errors.Is(err, ErrInviteInvalid):
		shared.WriteError(w, http.StatusUnauthorized, "invalid_invite", "invite token is invalid")
	case errors.Is(err, ErrInviteExpired):
		shared.WriteError(w, http.StatusGone, "invite_expired", "invite token has expired")
	case errors.Is(err, ErrInviteConsumed):
		shared.WriteError(w, http.StatusConflict, "invite_consumed", "invite has already been used or revoked")
	case err != nil:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	default:
		shared.WriteJSON(w, http.StatusOK, map[string]any{"org": o, "role": role})
	}
}

// handleLookup maps a service lookup error to the right status (mirrors
// tenants.routes.handleLookup).
func (rt *routes) handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		shared.WriteError(w, http.StatusNotFound, "not_found", "not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
