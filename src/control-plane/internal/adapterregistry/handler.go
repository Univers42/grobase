package adapterregistry

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

const msgNotFound = "database not found"

// routes binds the service + service token for handler methods.
type routes struct {
	svc          *Service
	serviceToken string
}

// Mount registers adapter-registry routes onto the shared mux.
//
// Identity model for the shadow phase: the trust boundary (Kong / gateway)
// injects the authenticated tenant as the `X-User-Id` header. The internal
// `/connect` and delete routes additionally require the service token,
// mirroring the legacy ServiceTokenGuard / RolesGuard.
//
// DELETE /databases/{id}/self is the caller-scoped delete for the self-serve
// dynamic builder (BUILDER): unlike the admin DELETE /databases/{id} (which
// bypasses RLS for operator teardown), it binds `AND tenant_id = $caller` in
// the SQL, so a mount UUID is NEVER a bearer capability — a tenant can only
// delete its OWN mount. It is service-token gated like /connect (the trust
// boundary forwards the asserted tenant header).
func Mount(mux *http.ServeMux, svc *Service, serviceToken string) {
	rt := &routes{svc: svc, serviceToken: serviceToken}
	mux.HandleFunc("POST /databases", rt.register)
	mux.HandleFunc("GET /databases", rt.list)
	mux.HandleFunc("GET /databases/{id}", rt.findOne)
	mux.HandleFunc("GET /databases/{id}/connect", rt.connect)
	mux.HandleFunc("DELETE /databases/{id}", rt.remove)
	mux.HandleFunc("DELETE /databases/{id}/self", rt.removeScoped)
}

func (rt *routes) register(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.requireUser(w, r)
	if !ok {
		return
	}
	var req RegisterDatabaseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return
	}
	if err := req.Validate(); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return
	}
	res, err := rt.svc.Register(r.Context(), userID, req)
	if err != nil {
		writeRegisterError(w, req, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, res)
}

func (rt *routes) list(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.requireUser(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.List(r.Context(), userID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *routes) findOne(w http.ResponseWriter, r *http.Request) {
	userID, ok := rt.requireUser(w, r)
	if !ok {
		return
	}
	db, err := rt.svc.FindOne(r.Context(), userID, r.PathValue("id"))
	if rt.handleLookupError(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, db)
}

func (rt *routes) connect(w http.ResponseWriter, r *http.Request) {
	if !validServiceToken(r, rt.serviceToken) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "service token required")
		return
	}
	userID, ok := rt.requireUser(w, r)
	if !ok {
		return
	}
	conn, err := rt.svc.GetConnection(r.Context(), userID, r.PathValue("id"))
	if rt.handleLookupError(w, err) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, conn)
}
