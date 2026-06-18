package adapterregistry

import (
	"net/http"

	"github.com/dlesieur/mini-baas/control-plane/internal/httpx"
)

// requireUser resolves the asserted identity, writing 401 and returning ok=false
// when it is missing or (under identity HMAC) unverifiable.
//
// Header precedence (post-M11 signed-envelope migration):
//  1. X-Baas-User-Id   — signed envelope user id
//  2. X-Baas-Tenant-Id — signed envelope tenant id (rows are keyed by tenant)
//  3. X-User-Id        — legacy raw header (compat mode only)
//  4. X-Tenant-Id      — legacy raw tenant header
//
// The TS service did full HMAC verification on the X-Baas-* headers; the Go
// service TRUSTS them by default (the data plane and adapter-registry sit on a
// private docker network, and write paths additionally require the service
// token). Audit residual O6: set ADAPTER_REGISTRY_IDENTITY_HMAC=1 to require an
// X-Baas-Identity-Auth signature over the asserted identity (see identity.go)
// so a peer on a flat bridge can no longer spoof identity.
func (rt *routes) requireUser(w http.ResponseWriter, r *http.Request) (string, bool) {
	userID, tenantID, resolved := resolveIdentityHeaders(r)
	if resolved == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"missing user/tenant header (X-Baas-User-Id, X-Baas-Tenant-Id, X-User-Id or X-Tenant-Id)")
		return "", false
	}
	if identityHMACEnabled() && !verifyIdentitySignature(r, rt.serviceToken, userID, tenantID) {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized",
			"invalid or missing identity signature ("+identityAuthHeader+")")
		return "", false
	}
	return resolved, true
}

// resolveIdentityHeaders reads the asserted user/tenant from the precedence
// header lists and returns (userID, tenantID, resolved). resolved preserves the
// original fallback: the tenant header alone identifies the row owner when no
// explicit user id is present.
func resolveIdentityHeaders(r *http.Request) (userID, tenantID, resolved string) {
	for _, h := range []string{"X-Baas-User-Id", "X-User-Id"} {
		if v := r.Header.Get(h); v != "" {
			userID = v
			break
		}
	}
	for _, h := range []string{"X-Baas-Tenant-Id", "X-Tenant-Id"} {
		if v := r.Header.Get(h); v != "" {
			tenantID = v
			break
		}
	}
	resolved = userID
	if resolved == "" {
		resolved = tenantID
	}
	return userID, tenantID, resolved
}
