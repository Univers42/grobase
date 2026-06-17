package identity

import (
	"crypto/subtle"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

// Defense-in-depth for the tenant-self authorization path.
//
// THE FINDING: several control-plane handlers authorize a tenant-scoped request
// on a RAW, unsigned `X-Baas-Tenant-Id` (or legacy `X-Tenant-Id`) header that
// equals the path {id} — with no independent crypto check. Today that is
// contained ONLY by Kong routing + ip-restriction: one misrouted/widened Kong
// route, or any in-cluster reach to tenant-control:3022, turns a forged header
// into cross-tenant access (the data plane re-derives the tenant from the
// verified api-key; these control-plane reads do not, so the header IS the
// authority). See the GOOD counter-pattern in tenants.selfServe.selfAuth, where
// the tenant is derived from a VERIFIED credential and there is no path {id}.
//
// THE FIX (this file): an OPT-IN, fail-closed HMAC over the asserted identity,
// promoted from the adapter-registry's O6 residual primitive (identity.go there)
// so every `tokenOrSelf` site reuses ONE mechanism instead of inventing a
// parallel one. It binds the asserted tenant id to a holder of the internal
// service token within a ±skew window, reusing the golden-vector-tested
// ComputeServiceSignature envelope (v1.<ts>.<hex>) — so a peer on a flat bridge
// can no longer spoof X-Baas-Tenant-Id even if it reaches the upstream directly.
//
// POSTURE — default OFF = byte-parity (this is load-bearing):
//   - TenantHeaderHMACEnabled() gates the whole feature on
//     TENANT_HEADER_IDENTITY_HMAC. When UNSET (the default), TenantSelfMatch is
//     byte-identical to the pre-existing `header == id` check, so every existing
//     gate (m76 self-read, m83/m84 self-serve, m107 passkeys, m110 sso) and the
//     unit tests that assert "matching header → 200" keep passing unchanged.
//   - When SET, a raw-header self-match ADDITIONALLY requires a valid
//     X-Baas-Identity-Auth signature over the asserted id; a forged header with
//     no (or a wrong/stale/spoofed) signature fails closed. The control-plane
//     SERVICE-TOKEN arm of each tokenOrSelf is unaffected — an admin caller never
//     relies on the header at all.
//
// This is the safe, reversible minimum. A deeper fix (deriving the tenant from a
// verified credential, as selfAuth does, so the header is never authoritative)
// is the right end state for the {id}-path admin/self handlers, but it requires
// each caller to forward a credential these internal routes do not receive
// today; the HMAC envelope closes the forge vector without that wider change.

// IdentityAuthHeader carries the v1 signature over the asserted identity tuple.
// Same header name the adapter-registry uses, so a caller mints ONE signature.
const IdentityAuthHeader = "X-Baas-Identity-Auth"

// TenantHeaderHMACEnabled reports whether opt-in identity-header HMAC
// verification is active for the tenant-self path. Default OFF preserves the
// pre-existing behavior (raw `header == id` authorizes) byte-for-byte.
func TenantHeaderHMACEnabled() bool {
	v := strings.TrimSpace(os.Getenv("TENANT_HEADER_IDENTITY_HMAC"))
	return v == "1" || strings.EqualFold(v, "true")
}

// CanonicalIdentity is the signed message for an identity HMAC: the user id and
// tenant id, newline-joined, so a signature for one identity cannot be replayed
// to assert another. Byte-identical to the adapter-registry's canonicalIdentity
// so ONE minted signature satisfies both verifiers.
func CanonicalIdentity(userID, tenantID string) string {
	return userID + "\n" + tenantID
}

// identitySkewSecs returns the ±window (default 120) a signature timestamp must
// fall within, reusing the same SERVICE_AUTH_SKEW_SECS knob as the service-auth
// HMAC so the two envelopes share one operational dial.
func identitySkewSecs() int64 {
	skew := int64(120)
	if v := os.Getenv("SERVICE_AUTH_SKEW_SECS"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			skew = n
		}
	}
	return skew
}

// VerifyIdentitySignature validates X-Baas-Identity-Auth against the canonical
// (userID, tenantID) tuple using the service token as the HMAC key. It mirrors
// VerifyServiceRequest's hmac arm (v1 envelope + ±skew window) but binds the
// identity tuple instead of method/path/body. Returns false on an empty token,
// a malformed header, an expired/early timestamp, or any signature mismatch.
//
// The canonical identity is the signed "path"; the method is the fixed sentinel
// "IDENTITY" and there is no body — exactly the adapter-registry construction,
// so a signature minted for one verifier is accepted by the other.
func VerifyIdentitySignature(r *http.Request, serviceToken, userID, tenantID string) bool {
	if serviceToken == "" {
		return false
	}
	hdr := r.Header.Get(IdentityAuthHeader)
	parts := strings.Split(hdr, ".")
	if len(parts) != 3 || parts[0] != "v1" {
		return false
	}
	ts, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return false
	}
	now := time.Now().Unix()
	skew := identitySkewSecs()
	if ts < now-skew || ts > now+skew {
		return false
	}
	want := serviceauth.ComputeServiceSignature(serviceToken, serviceauth.SignedRequest{
		Method: "IDENTITY", Path: CanonicalIdentity(userID, tenantID), TS: ts,
	})
	return subtle.ConstantTimeCompare([]byte(hdr), []byte(want)) == 1
}

// TenantSelfMatch reports whether the request authentically asserts membership
// in tenant `id` via the forwarded identity headers — the shared replacement for
// the open-coded `r.Header.Get("X-Baas-Tenant-Id") == id || ...` check that the
// {id}-path tokenOrSelf guards used.
//
// An empty id never matches (an untenanted deployment must fall back to the
// service token, never a bare header). The raw header must equal id; then, when
// TENANT_HEADER_IDENTITY_HMAC is ON, a valid X-Baas-Identity-Auth signature over
// the asserted (user, tenant) identity is ALSO required — so a forged header
// alone fails closed. The signed user id is taken from X-Baas-User-Id /
// X-User-Id when present (so a key-derived principal can be bound), defaulting
// to empty for a tenant-only assertion.
//
// Flag OFF (default): byte-identical to the previous `header == id` check.
func TenantSelfMatch(r *http.Request, serviceToken, id string) bool {
	if id == "" {
		return false
	}
	hdrTenant := r.Header.Get("X-Baas-Tenant-Id")
	if hdrTenant == "" {
		hdrTenant = r.Header.Get("X-Tenant-Id")
	}
	if hdrTenant != id {
		return false
	}
	if !TenantHeaderHMACEnabled() {
		return true
	}
	userID := r.Header.Get("X-Baas-User-Id")
	if userID == "" {
		userID = r.Header.Get("X-User-Id")
	}
	return VerifyIdentitySignature(r, serviceToken, userID, id)
}
