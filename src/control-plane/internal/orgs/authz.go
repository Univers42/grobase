package orgs

import (
	"context"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// authz.go — the org capability gate, factored into free functions so BOTH the org
// routes (handler.go) and the exported Authorizer (which the teams package reuses)
// share ONE implementation of the 404/403/JWT semantics that the m103 gate pins.

// resolveJWT resolves the calling human's GoTrue user uuid from the Authorization
// Bearer JWT. On any failure it writes the status and returns ok=false.
func resolveJWT(jwt jwtVerifier, w http.ResponseWriter, r *http.Request) (string, bool) {
	if jwt == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "not_implemented",
			"org API requires a JWT verifier (set GOTRUE_JWT_SECRET)")
		return "", false
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if auth == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "Authorization: Bearer <jwt> required")
		return "", false
	}
	id, err := jwt.Verify(auth)
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

// gateCapability resolves the caller's org role and checks the RBAC matrix: a
// non-member → opaque 404 (cross-org isolation by membership), a member lacking the
// capability → 403. On success it returns the caller's user id + role.
func gateCapability(svc *Service, jwt jwtVerifier, w http.ResponseWriter, r *http.Request, orgID, cap string) (userID string, role Role, ok bool) {
	userID, ok = resolveJWT(jwt, w, r)
	if !ok {
		return "", "", false
	}
	role, member := svc.MemberRole(r.Context(), orgID, userID)
	if !member {
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

// Authorizer is the EXPORTED org capability gate. The teams package holds one so its
// org-level checks reuse the identical 404/403/JWT semantics rather than re-deriving
// them (one source of truth — the m103 gate pins this behavior).
type Authorizer struct {
	svc *Service
	jwt jwtVerifier
}

// NewAuthorizer builds an Authorizer from the org service + a JWT verifier. A nil
// verifier makes every check answer 501 (no GoTrue secret configured).
func NewAuthorizer(svc *Service, jwt jwtVerifier) *Authorizer {
	return &Authorizer{svc: svc, jwt: jwt}
}

// AuthJWT resolves the caller's user id from the Bearer JWT (writes 401 on failure).
func (a *Authorizer) AuthJWT(w http.ResponseWriter, r *http.Request) (string, bool) {
	return resolveJWT(a.jwt, w, r)
}

// RequireCapability gates an org-level capability (404 non-member, 403 lacking cap).
func (a *Authorizer) RequireCapability(w http.ResponseWriter, r *http.Request, orgID, cap string) (string, Role, bool) {
	return gateCapability(a.svc, a.jwt, w, r, orgID, cap)
}

// MemberRole resolves the caller's org role (ok=false ⇒ not a member).
func (a *Authorizer) MemberRole(ctx context.Context, orgID, userID string) (Role, bool) {
	return a.svc.MemberRole(ctx, orgID, userID)
}
