package shared

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const idTestToken = "test-service-token"

// signTenantIdentity mints a valid X-Baas-Identity-Auth for (userID, tenantID).
func signTenantIdentity(token, userID, tenantID string, ts int64) string {
	return ComputeServiceSignature(token, "IDENTITY", CanonicalIdentity(userID, tenantID), nil, ts)
}

func reqWithHeaders(h map[string]string) *http.Request {
	r := httptest.NewRequest("GET", "/v1/tenants/T/usage", nil)
	for k, v := range h {
		r.Header.Set(k, v)
	}
	return r
}

// ── default (flag OFF) — byte-parity with the prior `header == id` check ──────

func TestTenantSelfMatch_DefaultTrustsMatchingHeader(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "")
	if !TenantSelfMatch(reqWithHeaders(map[string]string{"X-Baas-Tenant-Id": "T"}), idTestToken, "T") {
		t.Fatal("flag OFF: a matching X-Baas-Tenant-Id must authorize (parity)")
	}
}

func TestTenantSelfMatch_DefaultTrustsLegacyHeader(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "")
	if !TenantSelfMatch(reqWithHeaders(map[string]string{"X-Tenant-Id": "T"}), idTestToken, "T") {
		t.Fatal("flag OFF: a matching legacy X-Tenant-Id must authorize (parity)")
	}
}

func TestTenantSelfMatch_MismatchRejected(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "")
	// A tenant asserting ANOTHER tenant's id with its own header → no match.
	if TenantSelfMatch(reqWithHeaders(map[string]string{"X-Baas-Tenant-Id": "T"}), idTestToken, "T2") {
		t.Fatal("a header for T must NOT authorize id T2 (cross-tenant)")
	}
}

func TestTenantSelfMatch_EmptyIdNeverMatches(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "")
	// Untenanted deployment: an empty id must fall back to the service token,
	// never a bare/blank header (else a header-less request could self-authorize).
	if TenantSelfMatch(reqWithHeaders(map[string]string{"X-Baas-Tenant-Id": ""}), idTestToken, "") {
		t.Fatal("an empty id must never match (must require the service token)")
	}
	if TenantSelfMatch(reqWithHeaders(nil), idTestToken, "") {
		t.Fatal("no header + empty id must never match")
	}
}

func TestTenantSelfMatch_NoHeaderRejected(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "")
	if TenantSelfMatch(reqWithHeaders(nil), idTestToken, "T") {
		t.Fatal("no tenant header must not authorize")
	}
}

// ── flag ON — a forged header alone fails closed; a valid signature passes ────

func TestTenantSelfMatch_HMACAcceptsValidSignature(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	ts := time.Now().Unix()
	r := reqWithHeaders(map[string]string{
		"X-Baas-Tenant-Id": "T",
		"X-Baas-User-Id":   "user-1",
		IdentityAuthHeader: signTenantIdentity(idTestToken, "user-1", "T", ts),
	})
	if !TenantSelfMatch(r, idTestToken, "T") {
		t.Fatal("flag ON: a valid identity signature must authorize")
	}
}

func TestTenantSelfMatch_HMACAcceptsTenantOnlySignature(t *testing.T) {
	// No user header → the signed user id is empty; a signature over ("","T")
	// must still authorize (the metering/sso self-read carries no user id).
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	ts := time.Now().Unix()
	r := reqWithHeaders(map[string]string{
		"X-Baas-Tenant-Id": "T",
		IdentityAuthHeader: signTenantIdentity(idTestToken, "", "T", ts),
	})
	if !TenantSelfMatch(r, idTestToken, "T") {
		t.Fatal("flag ON: a valid tenant-only identity signature must authorize")
	}
}

func TestTenantSelfMatch_HMACRejectsForgedHeaderNoSignature(t *testing.T) {
	// THE FORGE VECTOR: a matching header with NO signature must fail closed.
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	r := reqWithHeaders(map[string]string{"X-Baas-Tenant-Id": "T"})
	if TenantSelfMatch(r, idTestToken, "T") {
		t.Fatal("flag ON: an unsigned (forged) tenant header must NOT authorize")
	}
}

func TestTenantSelfMatch_HMACRejectsSpoofedTenant(t *testing.T) {
	// A signature minted for tenant T must not authorize an asserted tenant T2.
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	ts := time.Now().Unix()
	r := httptest.NewRequest("GET", "/v1/tenants/T2/usage", nil)
	r.Header.Set("X-Baas-Tenant-Id", "T2") // attacker-asserted
	r.Header.Set(IdentityAuthHeader, signTenantIdentity(idTestToken, "", "T", ts))
	if TenantSelfMatch(r, idTestToken, "T2") {
		t.Fatal("flag ON: a signature for tenant T must not authorize tenant T2")
	}
}

func TestTenantSelfMatch_HMACRejectsWrongToken(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	ts := time.Now().Unix()
	r := reqWithHeaders(map[string]string{
		"X-Baas-Tenant-Id": "T",
		IdentityAuthHeader: signTenantIdentity("wrong-token", "", "T", ts),
	})
	if TenantSelfMatch(r, idTestToken, "T") {
		t.Fatal("flag ON: a signature keyed by the wrong service token must not authorize")
	}
}

func TestTenantSelfMatch_HMACRejectsExpiredTimestamp(t *testing.T) {
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	ts := time.Now().Unix() - 3600 // outside the ±120s skew
	r := reqWithHeaders(map[string]string{
		"X-Baas-Tenant-Id": "T",
		IdentityAuthHeader: signTenantIdentity(idTestToken, "", "T", ts),
	})
	if TenantSelfMatch(r, idTestToken, "T") {
		t.Fatal("flag ON: a stale (replayed) signature must not authorize")
	}
}

func TestTenantSelfMatch_HMACStillRequiresMatchingHeader(t *testing.T) {
	// Even with a valid signature for T, the raw header must equal the id —
	// a signature for T does not authorize id T2 when the header also says T2.
	t.Setenv("TENANT_HEADER_IDENTITY_HMAC", "1")
	ts := time.Now().Unix()
	r := httptest.NewRequest("GET", "/v1/tenants/T2/usage", nil)
	r.Header.Set("X-Baas-Tenant-Id", "T") // header says T, but id is T2
	r.Header.Set(IdentityAuthHeader, signTenantIdentity(idTestToken, "", "T", ts))
	if TenantSelfMatch(r, idTestToken, "T2") {
		t.Fatal("flag ON: header must equal id even with a valid signature")
	}
}

func TestVerifyIdentitySignature_EmptyTokenRejected(t *testing.T) {
	ts := time.Now().Unix()
	r := reqWithHeaders(map[string]string{IdentityAuthHeader: signTenantIdentity("", "", "T", ts)})
	if VerifyIdentitySignature(r, "", "", "T") {
		t.Fatal("an empty service token must never verify (fail closed)")
	}
}
