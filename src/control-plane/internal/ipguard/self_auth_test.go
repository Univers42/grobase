package ipguard

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/identity"
	"github.com/dlesieur/mini-baas/control-plane/internal/serviceauth"
)

const selfAuthToken = "ipguard-self-auth-token"

// selfRequest builds a CRUD request asserting tenant "T" by header, optionally
// carrying a valid identity signature over ("", "T").
func selfRequest(signed bool) *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/v1/tenants/T/ip-allowlist", nil)
	r.Header.Set("X-Baas-Tenant-Id", "T")
	if signed {
		sig := serviceauth.ComputeServiceSignature(selfAuthToken, serviceauth.SignedRequest{
			Method: "IDENTITY", Path: identity.CanonicalIdentity("", "T"), TS: time.Now().Unix(),
		})
		r.Header.Set(identity.IdentityAuthHeader, sig)
	}
	return r
}

// TestTokenOrSelf_HMACRejectsForgedHeader is C-2: with TENANT_HEADER_IDENTITY_HMAC
// on, a bare matching X-Baas-Tenant-Id (no signature) must not authorize.
func TestTokenOrSelf_HMACRejectsForgedHeader(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	rt := &routes{serviceToken: selfAuthToken}
	w := httptest.NewRecorder()
	if rt.tokenOrSelf(w, selfRequest(false), "T") {
		t.Fatal("flag ON: an unsigned tenant header must NOT authorize ipguard CRUD")
	}
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", w.Code)
	}
}

// TestTokenOrSelf_HMACAcceptsSignedHeader keeps the legitimate signed caller working.
func TestTokenOrSelf_HMACAcceptsSignedHeader(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	rt := &routes{serviceToken: selfAuthToken}
	if !rt.tokenOrSelf(httptest.NewRecorder(), selfRequest(true), "T") {
		t.Fatal("flag ON: a validly signed tenant header must authorize")
	}
}

// TestTokenOrSelf_FlagOffParity: unset flag keeps today's raw header match.
func TestTokenOrSelf_FlagOffParity(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "")
	rt := &routes{serviceToken: selfAuthToken}
	if !rt.tokenOrSelf(httptest.NewRecorder(), selfRequest(false), "T") {
		t.Fatal("flag OFF: a matching header must still authorize (byte-parity)")
	}
	if rt.tokenOrSelf(httptest.NewRecorder(), selfRequest(false), "T2") {
		t.Fatal("a header for T must never authorize T2")
	}
}
