package adapterregistry

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

const testToken = "test-service-token"

// signIdentity produces a valid X-Baas-Identity-Auth value for the given tuple.
func signIdentity(token, userID, tenantID string, ts int64) string {
	return shared.ComputeServiceSignature(token, "IDENTITY", canonicalIdentity(userID, tenantID), nil, ts)
}

func TestRequireUserDefaultTrustsHeaders(t *testing.T) {
	// Flag OFF (default): identity headers are trusted as before — no signature
	// required. Preserves the pre-existing private-network behavior.
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	rt := &routes{serviceToken: testToken}
	r := httptest.NewRequest("GET", "/databases", nil)
	r.Header.Set("X-Baas-User-Id", "user-1")
	w := httptest.NewRecorder()
	got, ok := rt.requireUser(w, r)
	if !ok || got != "user-1" {
		t.Fatalf("default mode: got=%q ok=%v, want user-1/true", got, ok)
	}
}

func TestRequireUserPrefersUserOverTenant(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	rt := &routes{serviceToken: testToken}
	r := httptest.NewRequest("GET", "/databases", nil)
	r.Header.Set("X-Baas-User-Id", "user-7")
	r.Header.Set("X-Baas-Tenant-Id", "tenant-9")
	w := httptest.NewRecorder()
	got, ok := rt.requireUser(w, r)
	if !ok || got != "user-7" {
		t.Fatalf("precedence: got=%q ok=%v, want user-7/true", got, ok)
	}
}

func TestRequireUserTenantOnlyFallback(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	rt := &routes{serviceToken: testToken}
	r := httptest.NewRequest("GET", "/databases", nil)
	r.Header.Set("X-Tenant-Id", "tenant-legacy")
	w := httptest.NewRecorder()
	got, ok := rt.requireUser(w, r)
	if !ok || got != "tenant-legacy" {
		t.Fatalf("tenant fallback: got=%q ok=%v, want tenant-legacy/true", got, ok)
	}
}

func TestRequireUserMissingHeaders(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "")
	rt := &routes{serviceToken: testToken}
	r := httptest.NewRequest("GET", "/databases", nil)
	w := httptest.NewRecorder()
	if _, ok := rt.requireUser(w, r); ok {
		t.Fatal("missing headers must be rejected")
	}
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", w.Code)
	}
}

func TestRequireUserHMACAcceptsValidSignature(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "1")
	rt := &routes{serviceToken: testToken}
	ts := time.Now().Unix()
	r := httptest.NewRequest("POST", "/databases", nil)
	r.Header.Set("X-Baas-User-Id", "user-1")
	r.Header.Set("X-Baas-Tenant-Id", "tenant-1")
	r.Header.Set(identityAuthHeader, signIdentity(testToken, "user-1", "tenant-1", ts))
	w := httptest.NewRecorder()
	got, ok := rt.requireUser(w, r)
	if !ok || got != "user-1" {
		t.Fatalf("valid signature: got=%q ok=%v code=%d, want user-1/true", got, ok, w.Code)
	}
}

func TestRequireUserHMACRejectsMissingSignature(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "1")
	rt := &routes{serviceToken: testToken}
	r := httptest.NewRequest("POST", "/databases", nil)
	r.Header.Set("X-Baas-User-Id", "user-1")
	w := httptest.NewRecorder()
	if _, ok := rt.requireUser(w, r); ok {
		t.Fatal("hmac mode must reject an unsigned identity header (forge vector)")
	}
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", w.Code)
	}
}

func TestRequireUserHMACRejectsSpoofedIdentity(t *testing.T) {
	// A signature minted for user-1 must not authorize an asserted user-2 — the
	// core anti-spoof property.
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "1")
	rt := &routes{serviceToken: testToken}
	ts := time.Now().Unix()
	r := httptest.NewRequest("POST", "/databases", nil)
	r.Header.Set("X-Baas-User-Id", "user-2") // attacker-asserted
	r.Header.Set(identityAuthHeader, signIdentity(testToken, "user-1", "", ts))
	w := httptest.NewRecorder()
	if _, ok := rt.requireUser(w, r); ok {
		t.Fatal("hmac mode must reject a signature minted for a different identity")
	}
}

func TestRequireUserHMACRejectsWrongToken(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "1")
	rt := &routes{serviceToken: testToken}
	ts := time.Now().Unix()
	r := httptest.NewRequest("POST", "/databases", nil)
	r.Header.Set("X-Baas-User-Id", "user-1")
	r.Header.Set(identityAuthHeader, signIdentity("wrong-token", "user-1", "", ts))
	w := httptest.NewRecorder()
	if _, ok := rt.requireUser(w, r); ok {
		t.Fatal("hmac mode must reject a signature keyed by the wrong service token")
	}
}

func TestRequireUserHMACRejectsExpiredTimestamp(t *testing.T) {
	t.Setenv("ADAPTER_REGISTRY_IDENTITY_HMAC", "1")
	rt := &routes{serviceToken: testToken}
	ts := time.Now().Unix() - 3600 // well outside the ±120s skew
	r := httptest.NewRequest("POST", "/databases", nil)
	r.Header.Set("X-Baas-User-Id", "user-1")
	r.Header.Set(identityAuthHeader, signIdentity(testToken, "user-1", "", ts))
	w := httptest.NewRecorder()
	if _, ok := rt.requireUser(w, r); ok {
		t.Fatal("hmac mode must reject a stale (replayed) signature")
	}
}
