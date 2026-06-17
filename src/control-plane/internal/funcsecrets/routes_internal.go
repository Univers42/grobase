package funcsecrets

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// resolve is internal-only: it returns DECRYPTED secrets and must be protected
// by the service token (the gateway also keeps /internal off the public router).
func (rt *routes) resolve(w http.ResponseWriter, r *http.Request) {
	if rt.serviceToken != "" && r.Header.Get("X-Internal-Service-Token") != rt.serviceToken {
		shared.WriteError(w, http.StatusUnauthorized, "unauthorized", "invalid service token")
		return
	}
	tenant := r.URL.Query().Get("tenant")
	if tenant == "" {
		shared.WriteError(w, http.StatusBadRequest, "bad_request", "tenant required")
		return
	}
	fn := r.URL.Query().Get("function")
	secrets, err := rt.svc.Resolve(r.Context(), tenant, fn)
	if err != nil {
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	shared.WriteJSON(w, http.StatusOK, secrets)
}

func requireTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-Tenant-Id", "X-Baas-User-Id", "X-Tenant-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"missing tenant header (X-Baas-Tenant-Id, X-Baas-User-Id, X-Tenant-Id or X-User-Id)")
	return "", false
}
