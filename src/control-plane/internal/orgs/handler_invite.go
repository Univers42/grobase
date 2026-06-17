package orgs

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// handler_invite.go — the org invite HTTP handlers (issue / list / revoke /
// accept) and the AcceptInvite error→status mapping.

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
	if writeInviteError(w, err) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"org": o, "role": role})
}

// writeInviteError maps an AcceptInvite error to its specific status (401/410/409
// / 500). Returns true when it wrote an error (the caller must stop); false on a
// nil error (success path continues).
func writeInviteError(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrInviteInvalid):
		shared.WriteError(w, http.StatusUnauthorized, "invalid_invite", "invite token is invalid")
	case errors.Is(err, ErrInviteExpired):
		shared.WriteError(w, http.StatusGone, "invite_expired", "invite token has expired")
	case errors.Is(err, ErrInviteConsumed):
		shared.WriteError(w, http.StatusConflict, "invite_consumed", "invite has already been used or revoked")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}
