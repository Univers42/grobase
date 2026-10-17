package authz

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// Scopes: a check reads, everything that shapes the graph writes.
const (
	ScopeRead  = "authz:read"
	ScopeWrite = "authz:write"
)

// Service is what the handlers need from the store.
type Service interface {
	Check(ctx context.Context, q Query) ([]Decision, error)
	GetModel(ctx context.Context, app string) ([]byte, error)
	PutModel(ctx context.Context, app string, raw []byte) error
	ReplaceTuples(ctx context.Context, app string, req TuplesRequest) (int, error)
}

// KeyAuth resolves the caller's tenant from an API key only; the tenant slug it
// returns is the app id for every query and write.
type KeyAuth interface {
	AuthenticateAPIKey(w http.ResponseWriter, r *http.Request) (tenantID string, scopes []string, ok bool)
}

// Deps groups the handler dependencies.
type Deps struct {
	Svc  Service
	Auth KeyAuth
	Log  *slog.Logger
}

type routes struct{ Deps }

// Mount registers the authz routes. The app is never read from a path or a
// body: it is the API key's tenant, so one key cannot reach another app.
func Mount(mux *http.ServeMux, d Deps) {
	rt := &routes{d}
	mux.HandleFunc("PUT /v1/authz/model", rt.putModel)
	mux.HandleFunc("GET /v1/authz/model", rt.getModel)
	mux.HandleFunc("POST /v1/authz/tuples", rt.postTuples)
	mux.HandleFunc("POST /v1/authz/check", rt.check)
	mux.HandleFunc("POST /v1/authz/check-batch", rt.checkBatch)
}

// app authenticates by API key and enforces scope; on failure the response is
// already written.
func (rt *routes) app(w http.ResponseWriter, r *http.Request, need string) (string, bool) {
	app, scopes, ok := rt.Auth.AuthenticateAPIKey(w, r)
	if !ok {
		return "", false
	}
	if !hasScope(scopes, need) {
		httpx.WriteError(w, http.StatusForbidden, "forbidden", "scope '"+need+"' required")
		return "", false
	}
	return app, true
}

// hasScope reports whether scopes grant want; admin is a superset, as in tenants.
func hasScope(scopes []string, want string) bool {
	for _, s := range scopes {
		if s == want || s == "admin" {
			return true
		}
	}
	return false
}

// fail maps a service error to a status. A store failure or a full gate is 503,
// never a 4xx, so a caller cannot mistake "could not check" for "no".
func (rt *routes) fail(w http.ResponseWriter, err error) {
	var dropped *DroppedError
	switch {
	case errors.As(err, &dropped):
		httpx.WriteJSON(w, http.StatusConflict, map[string]any{
			"error":   "model_drops_tuples",
			"message": dropped.Error(), "relations": dropped.Relations, "statusCode": http.StatusConflict,
		})
	case errors.Is(err, ErrNoModel):
		httpx.WriteError(w, http.StatusConflict, "no_model", "PUT /v1/authz/model first")
	case errors.Is(err, ErrInvalidModel), errors.Is(err, ErrInvalidTuples), errors.Is(err, ErrInvalidName):
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	case errors.Is(err, ErrUnknownPermission):
		httpx.WriteError(w, http.StatusBadRequest, "unknown_permission", err.Error())
	case errors.Is(err, ErrUnavailable), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		w.Header().Set("Retry-After", "1")
		httpx.WriteError(w, http.StatusServiceUnavailable, "authz_unavailable", "authz could not answer; retry")
	default:
		rt.Log.Error("authz request failed", "err", err)
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", "internal error")
	}
}
