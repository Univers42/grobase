package teams

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handlers_member.go — team membership HTTP handlers (org-admin OR team-manager).

func (rt *routes) addTeamMember(w http.ResponseWriter, r *http.Request) {
	orgID, teamID := r.PathValue("orgId"), r.PathValue("teamId")
	userID, ok := rt.requireTeamMember(w, r, orgID, teamID)
	if !ok {
		return
	}
	var req AddTeamMemberRequest
	if !decodeBody(w, r, &req) {
		return
	}
	if req.UserID == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "user_id is required")
		return
	}
	if err := rt.svc.AddTeamMember(r.Context(), orgID, teamID, req, userID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"added": true})
}

func (rt *routes) removeTeamMember(w http.ResponseWriter, r *http.Request) {
	orgID, teamID := r.PathValue("orgId"), r.PathValue("teamId")
	actor, ok := rt.requireTeamMember(w, r, orgID, teamID)
	if !ok {
		return
	}
	if err := rt.svc.RemoveTeamMember(r.Context(), orgID, teamID, r.PathValue("userId"), actor); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"removed": true})
}

func (rt *routes) listTeamMembers(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapOrgRead); !ok {
		return
	}
	list, err := rt.svc.ListTeamMembers(r.Context(), orgID, r.PathValue("teamId"))
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}
