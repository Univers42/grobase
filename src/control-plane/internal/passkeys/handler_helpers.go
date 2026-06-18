package passkeys

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
	"github.com/dlesieur/mini-baas/control-plane/internal/identity"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// decodeFinish parses the begin→finish bridge body and validates the two
// required fields. A finish with no challenge id or no response is a 400.
func (rt *routes) decodeFinish(w http.ResponseWriter, r *http.Request) (finishRequest, bool) {
	var req finishRequest
	if err := decodeJSON(r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", err.Error())
		return finishRequest{}, false
	}
	if strings.TrimSpace(req.ChallengeID) == "" {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "challenge_id required")
		return finishRequest{}, false
	}
	if len(req.Response) == 0 {
		httpx.WriteError(w, http.StatusBadRequest, "validation_error", "response required")
		return finishRequest{}, false
	}
	return req, true
}

// writeErr maps the service sentinels to HTTP status:
//
//	ErrChallengeNotFound -> 404 (missing/expired/replayed challenge)
//	ErrNoCredentials     -> 404 (user has no passkey to authenticate)
//	ErrAssertionRejected -> 401 (wrong key / wrong challenge / cross-user / bad sig)
//	anything else        -> 500
func (rt *routes) writeErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrAssertionRejected):
		httpx.WriteError(w, http.StatusUnauthorized, "assertion_rejected", "passkey authentication failed")
	case errors.Is(err, ErrChallengeNotFound):
		httpx.WriteError(w, http.StatusNotFound, "challenge_not_found", ErrChallengeNotFound.Error())
	case errors.Is(err, ErrNoCredentials):
		httpx.WriteError(w, http.StatusNotFound, "no_credentials", ErrNoCredentials.Error())
	default:
		httpx.WriteError(w, http.StatusInternalServerError, "internal_error", err.Error())
	}
}

// tokenOrSelf authorises a begin call by either a control-plane service token
// (admin) or a tenant-self assertion via X-Baas-Tenant-Id (a tenant acting
// WITHIN its own tenant) — byte-identical to audit.routes.tokenOrSelf. For an
// untenanted (empty) deployment a bare service token is required (TenantSelfMatch
// never matches an empty id), so a public unauthenticated begin is impossible.
//
// The self arm goes through identity.TenantSelfMatch: when TENANT_HEADER_IDENTITY_HMAC
// is set, a forged X-Baas-Tenant-Id cannot START a ceremony for another tenant's
// user on its own (a valid X-Baas-Identity-Auth signature over the asserted id is
// required); OFF (default) it is the unchanged `tenantID != "" && header == id`
// check (parity). The service-token (admin) arm never relies on the header.
func (rt *routes) tokenOrSelf(w http.ResponseWriter, r *http.Request, tenantID string) bool {
	if serviceauth.VerifyServiceRequest(r, rt.serviceToken) {
		return true
	}
	if identity.TenantSelfMatch(r, rt.serviceToken, tenantID) {
		return true
	}
	httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
		"service token or matching tenant header required")
	return false
}

// tenantOf reads the tenant the request acts within (the same signal tokenOrSelf
// matches). Empty for untenanted / single-tenant deployments.
func tenantOf(r *http.Request) string {
	if v := r.Header.Get("X-Baas-Tenant-Id"); v != "" {
		return v
	}
	return r.Header.Get("X-Tenant-Id")
}

// decodeJSON reads a JSON body with a cap large enough for an attestation object
// (a few KiB) but bounded against abuse.
func decodeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 256<<10))
	if err := dec.Decode(v); err != nil {
		if errors.Is(err, io.EOF) {
			return errors.New("empty body")
		}
		return err
	}
	return nil
}
