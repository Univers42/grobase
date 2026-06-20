package teams

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/orgs"
)

// handlers_token.go — scoped-token HTTP handlers. The non-escalation check lives in
// the service (CreateToken → ErrEscalation when the role exceeds the issuer's).

func (rt *routes) createToken(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapTokenIssue)
	if !ok {
		return
	}
	var req TokenCreateRequest
	if !decodeBody(w, r, &req) {
		return
	}
	resp, err := rt.svc.CreateToken(r.Context(), orgID, req, userID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, resp)
}

func (rt *routes) listTokens(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	if _, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapTokenIssue); !ok {
		return
	}
	list, err := rt.svc.ListTokens(r.Context(), orgID)
	if err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, list)
}

func (rt *routes) revokeToken(w http.ResponseWriter, r *http.Request) {
	orgID := r.PathValue("orgId")
	userID, _, ok := rt.auth.RequireCapability(w, r, orgID, orgs.CapTokenIssue)
	if !ok {
		return
	}
	if err := rt.svc.RevokeToken(r.Context(), orgID, r.PathValue("tokenId"), userID); err != nil {
		mapErr(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}
