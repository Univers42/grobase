package sso

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// writeErr maps the service sentinels to HTTP status:
//
//	ErrStateNotFound      -> 401 (missing/expired/replayed state — single-use)
//	ErrTokenRejected      -> 401 (id_token failed verification)
//	ErrConnectionNotFound -> 404
//	ErrConflict           -> 409
//	ErrValidation         -> 400
//	anything else         -> 500
func (rt *routes) writeErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrStateNotFound):
		shared.WriteError(w, http.StatusUnauthorized, "state_rejected", ErrStateNotFound.Error())
	case errors.Is(err, ErrTokenRejected):
		shared.WriteError(w, http.StatusUnauthorized, "token_rejected", "id_token verification failed")
	case errors.Is(err, ErrConnectionNotFound):
		shared.WriteError(w, http.StatusNotFound, "connection_not_found", ErrConnectionNotFound.Error())
	case errors.Is(err, ErrConflict):
		shared.WriteError(w, http.StatusConflict, "conflict", ErrConflict.Error())
	case errors.Is(err, ErrValidation):
		shared.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
	default:
		shared.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}

// tokenOrSelf authorises an admin call (register/list a tenant's IdP connections,
// keyed by the {id} path segment) by either a control-plane service token or a
// tenant-self assertion via X-Baas-Tenant-Id — the same shape
// passkeys.routes.tokenOrSelf / audit use. For an untenanted (empty) deployment a
// bare service token is required (TenantSelfMatch never matches an empty id).
//
// The self arm goes through shared.TenantSelfMatch: when TENANT_HEADER_IDENTITY_HMAC
// is set, a forged X-Baas-Tenant-Id cannot register/list ANOTHER tenant's SSO
// connections on its own (a valid X-Baas-Identity-Auth signature over the asserted
// {id} is required); OFF (default) it is the unchanged `tenantID != "" && header
// == id` check (parity). The service-token (admin) arm never relies on the header.
func (rt *routes) tokenOrSelf(w http.ResponseWriter, r *http.Request, tenantID string) bool {
	if shared.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if shared.TenantSelfMatch(r, rt.serviceToken, tenantID) {
		return true
	}
	shared.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"service token or matching tenant header required")
	return false
}

// tenantOf reads the tenant the request acts within (used by the begin path to
// scope an email-domain lookup). Empty for untenanted / single-tenant deployments.
func tenantOf(r *http.Request) string {
	if v := r.Header.Get("X-Baas-Tenant-Id"); v != "" {
		return v
	}
	return r.Header.Get("X-Tenant-Id")
}

// decodeJSON reads a JSON body with a bounded cap.
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 64<<10))
	if err := dec.Decode(v); err != nil {
		if errors.Is(err, io.EOF) {
			return errors.New("empty body")
		}
		return err
	}
	return nil
}
