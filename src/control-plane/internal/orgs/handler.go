package orgs

import (
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
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
		httpx.WriteError(w, http.StatusNotImplemented, "not_implemented",
			"org API requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		return "", false
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if auth == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "Authorization: Bearer <jwt> required")
		return "", false
	}
	id, err := rt.jwt.Verify(auth)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
		return "", false
	}
	if id.UserID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_token", "token missing sub")
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
		httpx.WriteError(w, http.StatusNotFound, "not_found", "org not found")
		return "", "", false
	}
	if !Can(role, cap) {
		httpx.WriteError(w, http.StatusForbidden, "forbidden",
			"your org role ("+string(role)+") may not perform "+cap)
		return "", "", false
	}
	return userID, role, true
}

// handleLookup maps a service lookup error to the right status (mirrors
// tenants.routes.handleLookup).
func (rt *routes) handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "not found")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
