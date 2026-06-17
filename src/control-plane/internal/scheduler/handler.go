package scheduler

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// Mount registers function-schedule routes onto the shared mux. Tenant-scoped
// via the forwarded envelope headers (X-Baas-Tenant-Id / X-Baas-User-Id).
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/function-schedules", rt.create)
	mux.HandleFunc("GET /v1/function-schedules", rt.list)
	mux.HandleFunc("PATCH /v1/function-schedules/{id}", rt.update)
	mux.HandleFunc("DELETE /v1/function-schedules/{id}", rt.remove)
}

type routes struct {
	svc          *Service
	serviceToken string
}

func handleLookup(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, ErrNotFound):
		httpx.WriteError(w, http.StatusNotFound, "not_found", "function schedule not found")
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
}

func requireTenant(w http.ResponseWriter, r *http.Request) (string, bool) {
	for _, h := range []string{"X-Baas-Tenant-Id", "X-Baas-User-Id", "X-Tenant-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			return v, true
		}
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"missing tenant header (X-Baas-Tenant-Id, X-Baas-User-Id, X-Tenant-Id or X-User-Id)")
	return "", false
}
