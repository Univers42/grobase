package tenants

import (
	"encoding/json"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// selfBootstrap is the GoTrue-JWT-authenticated counterpart to /bootstrap.
//
// Closes the signup -> first request loop: the just-signed-up user presents
// their JWT, we resolve their user id from the `sub` claim, find the tenant
// auto-provisioned by migration 033's trigger (or create one defensively),
// and issue a first API key. The cleartext key is returned ONCE; subsequent
// calls return `key_reuse: true` without exposing a new secret.
//
// Optional JSON body: { "default_key_name": "primary" }. Defaults to "default".
func (rt *routes) selfBootstrap(w http.ResponseWriter, r *http.Request) {
	identity, ok := rt.authJWTIdentity(w, r)
	if !ok {
		return
	}
	keyName, ok := decodeKeyName(w, r)
	if !ok {
		return
	}
	out, err := rt.svc.BootstrapForUser(r.Context(), identity.UserID, identity.Email, keyName)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	status := http.StatusOK
	if out.Created || out.APIKey != nil {
		status = http.StatusCreated
	}
	httpx.WriteJSON(w, status, out)
}

// authJWTIdentity verifies the Authorization: Bearer <jwt>, returning the
// identity. ok=false means a 501/401 was already written (jwt unconfigured,
// missing header, or invalid token).
func (rt *routes) authJWTIdentity(w http.ResponseWriter, r *http.Request) (VerifiedIdentity, bool) {
	if rt.jwt == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "not_implemented",
			"tenant-control is not configured with GOTRUE_JWT_SECRET")
		return VerifiedIdentity{}, false
	}
	auth := r.Header.Get("Authorization")
	if auth == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "Authorization: Bearer <jwt> required")
		return VerifiedIdentity{}, false
	}
	identity, err := rt.jwt.Verify(auth)
	if err != nil {
		httpx.WriteError(w, http.StatusUnauthorized, "invalid_token", err.Error())
		return VerifiedIdentity{}, false
	}
	return identity, true
}

// decodeKeyName reads the optional { "default_key_name": ... } body; ok=false
// means a malformed body was already answered with 400.
func decodeKeyName(w http.ResponseWriter, r *http.Request) (string, bool) {
	if r.ContentLength <= 0 {
		return "", true
	}
	var body struct {
		DefaultKeyName string `json:"default_key_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "bad_request", msgInvalidJSON)
		return "", false
	}
	return body.DefaultKeyName, true
}
