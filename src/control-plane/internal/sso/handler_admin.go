package sso

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// ── admin handlers (register/list a tenant's connections) ────────────────────

func (rt *routes) register(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	var in RegisterInput
	if err := decodeJSON(r, &in); err != nil {
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	in.TenantID = tenantID
	conn, err := rt.svc.RegisterConnection(r.Context(), in)
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusCreated, conn)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	tenantID := r.PathValue("id")
	if !rt.tokenOrSelf(w, r, tenantID) {
		return
	}
	conns, err := rt.svc.ListConnections(r.Context(), tenantID)
	if err != nil {
		rt.writeErr(w, err)
		return
	}
	shared.WriteJSON(w, http.StatusOK, map[string]any{"connections": conns})
}
