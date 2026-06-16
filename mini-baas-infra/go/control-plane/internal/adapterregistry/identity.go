package adapterregistry

import (
	"crypto/subtle"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

// Audit residual O6: adapter-registry historically TRUSTED the gateway-injected
// `X-Baas-*` identity headers without verification, on the assumption that the
// private docker network is a trust boundary. A flat single-bridge network makes
// that assumption thin (anything on the bridge can forge identity), so this adds
// an OPT-IN HMAC over the identity headers.
//
// Posture (default OFF — current trust model is unchanged unless the flag is set):
//   - identityHMACEnabled() gates the whole feature on ADAPTER_REGISTRY_IDENTITY_HMAC.
//   - When ON, a caller must present X-Baas-Identity-Auth: a v1 signature (the
//     same v1.<ts>.<hex> envelope as the service-auth HMAC, reusing
//     shared.ComputeServiceSignature) computed over the canonical identity
//     string "<user-id>\n<tenant-id>" as the signed "path", keyed by the same
//     service token the write routes already verify. This binds the asserted
//     identity to a holder of the service token within a ±skew window, so a peer
//     on the bridge can no longer spoof X-Baas-User-Id / X-Baas-Tenant-Id.
//
// This intentionally reuses the existing, golden-vector-tested HMAC primitive
// rather than introducing a second signing scheme. It does NOT touch the
// service-token write guard (validServiceToken) — it is an additional identity
// integrity check layered in front of requireUser.

const identityAuthHeader = "X-Baas-Identity-Auth"

// identityHMACEnabled reports whether opt-in identity-header HMAC verification is
// active. Default OFF preserves the pre-existing private-network trust model.
func identityHMACEnabled() bool {
	v := strings.TrimSpace(os.Getenv("ADAPTER_REGISTRY_IDENTITY_HMAC"))
	return v == "1" || strings.EqualFold(v, "true")
}

// canonicalIdentity is the signed message for identity HMAC: the user id and
// tenant id (empty if absent), newline-joined, so a signature for one identity
// cannot be replayed to assert another.
func canonicalIdentity(userID, tenantID string) string {
	return userID + "\n" + tenantID
}

// verifyIdentitySignature validates X-Baas-Identity-Auth against the canonical
// identity using the service token as the HMAC key. Mirrors the verification
// shape of shared.VerifyServiceRequest (v1 envelope + ±skew window) but binds
// the identity tuple instead of method/path/body. Returns false on any
// malformed header, expired/early timestamp, or signature mismatch.
func verifyIdentitySignature(r *http.Request, serviceToken, userID, tenantID string) bool {
	if serviceToken == "" {
		return false
	}
	hdr := r.Header.Get(identityAuthHeader)
	parts := strings.Split(hdr, ".")
	if len(parts) != 3 || parts[0] != "v1" {
		return false
	}
	ts, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil {
		return false
	}
	skew := int64(120)
	if v := os.Getenv("SERVICE_AUTH_SKEW_SECS"); v != "" {
		if n, perr := strconv.ParseInt(v, 10, 64); perr == nil && n > 0 {
			skew = n
		}
	}
	now := time.Now().Unix()
	if ts < now-skew || ts > now+skew {
		return false
	}
	// Reuse the golden-vector-tested HMAC primitive: the canonical identity is
	// the signed "path"; method is fixed and there is no body.
	want := shared.ComputeServiceSignature(serviceToken, "IDENTITY", canonicalIdentity(userID, tenantID), nil, ts)
	return subtle.ConstantTimeCompare([]byte(hdr), []byte(want)) == 1
}
