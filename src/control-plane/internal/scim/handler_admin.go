package scim

import (
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// handler_admin.go — the admin (service-token) surface: issue / revoke a SCIM
// bearer for a tenant. Split out of handler.go to keep each file at ≤5 funcs;
// behavior is byte-identical.

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
