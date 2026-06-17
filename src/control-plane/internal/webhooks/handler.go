package webhooks

import (
	"errors"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Mount registers webhook routes onto the shared mux.
//
// Identity: post-M11 the trust boundary forwards signed envelope headers
// (X-Baas-Tenant-Id / X-Baas-User-Id). Webhook secrets are tenant-scoped
// secrets and are NEVER returned by list/get — they are write-only fields.
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /v1/webhooks", rt.create)
	mux.HandleFunc("GET /v1/webhooks", rt.list)
	mux.HandleFunc("GET /v1/webhooks/{id}", rt.findOne)
	mux.HandleFunc("PATCH /v1/webhooks/{id}", rt.update)
	mux.HandleFunc("DELETE /v1/webhooks/{id}", rt.remove)
	mux.HandleFunc("GET /v1/webhooks/{id}/deliveries", rt.deliveries)
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
		shared.WriteError(w, http.StatusNotFound, "not_found", "webhook not found")
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
	return true
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
