package tenants

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

func (rt *routes) issueKey(w http.ResponseWriter, r *http.Request) {
	var req IssueKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	out, err := rt.svc.IssueKey(r.Context(), r.PathValue("id"), req)
	if err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusCreated, out)
}

func (rt *routes) listKeys(w http.ResponseWriter, r *http.Request) {
	out, err := rt.svc.ListKeys(r.Context(), r.PathValue("id"))
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) revokeKey(w http.ResponseWriter, r *http.Request) {
	if rt.handleLookup(w, rt.svc.RevokeKey(r.Context(), r.PathValue("id"), r.PathValue("keyId"))) {
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]bool{"revoked": true})
}

func (rt *routes) verifyKey(w http.ResponseWriter, r *http.Request) {
	var req VerifyKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return
	}
	out, err := rt.svc.VerifyKey(r.Context(), req.Key)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	status := http.StatusOK
	if !out.Valid {
		status = http.StatusUnauthorized
	}
	shared.WriteJSON(w, status, out)
}
