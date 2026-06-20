package teams

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handler.go — the /v1/orgs/{orgId}/teams|projects/{projectId}/grants|tokens routes.
// Mount is called ONLY when RBAC_HIERARCHY_ENABLED is truthy (cmd/.../mount_rbac.go),
// so OFF ⇒ none of these routes exist (404 = byte-parity). Org-level capability gates
// reuse orgs.Authorizer (one source of truth for the 404/403/JWT semantics).

type routes struct {
	svc  *Service
	auth *orgs.Authorizer
}

// Deps groups the team route dependencies (the service + the shared org authorizer).
type Deps struct {
	Svc  *Service
	Auth *orgs.Authorizer
}

// Mount registers the RBAC-hierarchy routes onto the shared mux. The static
// /grants & /tokens segments and the {teamId}/members wildcard follow net/http
// most-specific-pattern precedence, exactly as the orgs routes do.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{svc: d.Svc, auth: d.Auth}

	mux.HandleFunc("POST /v1/orgs/{orgId}/teams", rt.createTeam)
	mux.HandleFunc("GET /v1/orgs/{orgId}/teams", rt.listTeams)
	mux.HandleFunc("GET /v1/orgs/{orgId}/teams/{teamId}", rt.getTeam)
	mux.HandleFunc("PATCH /v1/orgs/{orgId}/teams/{teamId}", rt.updateTeam)
	mux.HandleFunc("DELETE /v1/orgs/{orgId}/teams/{teamId}", rt.deleteTeam)

	mux.HandleFunc("POST /v1/orgs/{orgId}/teams/{teamId}/members", rt.addTeamMember)
	mux.HandleFunc("DELETE /v1/orgs/{orgId}/teams/{teamId}/members/{userId}", rt.removeTeamMember)
	mux.HandleFunc("GET /v1/orgs/{orgId}/teams/{teamId}/members", rt.listTeamMembers)

	mux.HandleFunc("POST /v1/orgs/{orgId}/projects/{projectId}/grants", rt.grantRole)
	mux.HandleFunc("GET /v1/orgs/{orgId}/projects/{projectId}/grants", rt.listGrants)
	mux.HandleFunc("DELETE /v1/orgs/{orgId}/projects/{projectId}/grants/{grantId}", rt.revokeGrant)
	mux.HandleFunc("GET /v1/orgs/{orgId}/projects/{projectId}/effective", rt.effectiveRole)

	mux.HandleFunc("POST /v1/orgs/{orgId}/tokens", rt.createToken)
	mux.HandleFunc("GET /v1/orgs/{orgId}/tokens", rt.listTokens)
	mux.HandleFunc("DELETE /v1/orgs/{orgId}/tokens/{tokenId}", rt.revokeToken)
}

// requireTeamMember gates the add/remove-member ops: an org admin (CapTeamMember) OR
// a manager of the team itself may mutate membership. A non-member of the org → 404;
// a member who is neither → 403.
func (rt *routes) requireTeamMember(w http.ResponseWriter, r *http.Request, orgID, teamID string) (string, bool) {
	userID, ok := rt.auth.AuthJWT(w, r)
	if !ok {
		return "", false
	}
	role, member := rt.auth.MemberRole(r.Context(), orgID, userID)
	if !member {
		httpx.WriteError(w, http.StatusNotFound, "not_found", "org not found")
		return "", false
	}
	if orgs.Can(role, orgs.CapTeamMember) || rt.svc.isTeamManager(r.Context(), teamID, userID) {
		return userID, true
	}
	httpx.WriteError(w, http.StatusForbidden, "forbidden", "not an org admin or team manager")
	return "", false
}

// decodeBody decodes the JSON request body, writing 400 on failure.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON")
		return false
	}
	return true
}

// mapErr maps a teams sentinel error to the right HTTP status.
func mapErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, ErrConflict):
		httpx.WriteError(w, http.StatusConflict, "conflict", err.Error())
	case errors.Is(err, ErrEscalation), errors.Is(err, ErrForbidden):
		httpx.WriteError(w, http.StatusForbidden, "forbidden", err.Error())
	case errors.Is(err, ErrBadRole), errors.Is(err, ErrBadScope):
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}
