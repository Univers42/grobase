package shared

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// Golden vector shared with the Rust (service_auth.rs) and TS implementations —
// all three languages must produce byte-identical signatures.
func TestComputeServiceSignatureGoldenVector(t *testing.T) {
	got := ComputeServiceSignature("test-token", "POST", "/v1/keys/verify", []byte(`{"key":"abc"}`), 1700000000)
	want := "v1.1700000000.b2e684210cc7e80998388c89afe88d2fbd4fd9a7492289724f7fd3f15075189e"
	if got != want {
		t.Fatalf("POST vector mismatch:\n got %s\nwant %s", got, want)
	}
	gotGet := ComputeServiceSignature("test-token", "GET", "/databases/db1/connect", nil, 1700000000)
	wantGet := "v1.1700000000.d53d261c30ba227cb3ab770a0a3c936e0fc0cd7385855339ba60b1a172b21b6b"
	if gotGet != wantGet {
		t.Fatalf("GET vector mismatch:\n got %s\nwant %s", gotGet, wantGet)
	}
}

func TestVerifyServiceRequestStaticDefault(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "")
	r := httptest.NewRequest("POST", "/v1/keys/verify", bytes.NewReader([]byte(`{}`)))
	r.Header.Set("X-Service-Token", "secret")
	if !VerifyServiceRequest(r, "secret") {
		t.Fatal("static mode must accept the correct token")
	}
	r.Header.Set("X-Service-Token", "wrong")
	if VerifyServiceRequest(r, "secret") {
		t.Fatal("static mode must reject a wrong token")
	}
}

// TestVerifyServiceRequestRotateStatic proves the in-repo G-Rotate half in
// static mode: during the window (PREV set) BOTH the current and previous tokens
// verify; an unrelated third token is rejected; after the window (PREV cleared)
// the old token is REJECTED — the load-bearing arm.
func TestVerifyServiceRequestRotateStatic(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "")
	const keyA = "key-A-old"
	const keyB = "key-B-new"

	req := func(tok string) *http.Request {
		r := httptest.NewRequest("POST", "/v1/keys/verify", bytes.NewReader([]byte(`{}`)))
		r.Header.Set("X-Service-Token", tok)
		return r
	}

	// Default (single key, PREV empty): only the current token works.
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", "")
	if !VerifyServiceRequest(req(keyA), keyA) {
		t.Fatal("single-key: current token must verify")
	}
	if VerifyServiceRequest(req(keyB), keyA) {
		t.Fatal("single-key: a different token must be rejected")
	}

	// Rotation window: primary=keyB, PREV=keyA. BOTH verify; a third is rejected.
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", keyA)
	if !VerifyServiceRequest(req(keyB), keyB) {
		t.Fatal("window: newly issued (current) token must verify")
	}
	if !VerifyServiceRequest(req(keyA), keyB) {
		t.Fatal("window: in-flight previous token must STILL verify (no mid-rotation outage)")
	}
	if VerifyServiceRequest(req("key-C-unrelated"), keyB) {
		t.Fatal("window: an unrelated third token must be rejected")
	}

	// Window closed (PREV cleared): only keyB works, keyA is REJECTED.
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", "")
	if !VerifyServiceRequest(req(keyB), keyB) {
		t.Fatal("post-window: current token must verify")
	}
	if VerifyServiceRequest(req(keyA), keyB) {
		t.Fatal("post-window: previous token MUST be rejected (load-bearing)")
	}
}

// TestVerifyServiceRequestRotateHMAC proves the same dual-key window in hmac
// mode, where the signature itself is keyed by the token.
func TestVerifyServiceRequestRotateHMAC(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "hmac")
	const keyA = "key-A-old"
	const keyB = "key-B-new"
	body := []byte(`{"key":"abc"}`)

	signed := func(tok string) *http.Request {
		ts := time.Now().Unix()
		r := httptest.NewRequest("POST", "/v1/keys/verify", bytes.NewReader(body))
		r.Header.Set("X-Service-Auth", ComputeServiceSignature(tok, "POST", "/v1/keys/verify", body, ts))
		return r
	}

	// Rotation window: primary=keyB, PREV=keyA.
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", keyA)
	if !VerifyServiceRequest(signed(keyB), keyB) {
		t.Fatal("hmac window: signature under current token must verify")
	}
	if !VerifyServiceRequest(signed(keyA), keyB) {
		t.Fatal("hmac window: in-flight signature under previous token must STILL verify")
	}
	if VerifyServiceRequest(signed("key-C-unrelated"), keyB) {
		t.Fatal("hmac window: unrelated-key signature must be rejected")
	}

	// Window closed.
	t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", "")
	if VerifyServiceRequest(signed(keyA), keyB) {
		t.Fatal("hmac post-window: previous-key signature MUST be rejected (load-bearing)")
	}
	if !VerifyServiceRequest(signed(keyB), keyB) {
		t.Fatal("hmac post-window: current-key signature must verify")
	}
}

func TestVerifyServiceRequestHMAC(t *testing.T) {
	t.Setenv("SERVICE_TOKEN_MODE", "hmac")
	body := []byte(`{"key":"abc"}`)
	ts := time.Now().Unix()

	r := httptest.NewRequest("POST", "/v1/keys/verify", bytes.NewReader(body))
	r.Header.Set("X-Service-Auth", ComputeServiceSignature("secret", "POST", "/v1/keys/verify", body, ts))
	if !VerifyServiceRequest(r, "secret") {
		t.Fatal("hmac mode must accept a valid signature")
	}
	// Body must be restored for the handler.
	rest := make([]byte, len(body))
	if n, _ := r.Body.Read(rest); n != len(body) || !bytes.Equal(rest, body) {
		t.Fatal("body was not restored after verification")
	}

	// Plain static token is REJECTED in hmac mode (token never on the wire).
	r2 := httptest.NewRequest("POST", "/v1/keys/verify", bytes.NewReader(body))
	r2.Header.Set("X-Service-Token", "secret")
	if VerifyServiceRequest(r2, "secret") {
		t.Fatal("hmac mode must reject a plain static token")
	}

	// Tampered body fails.
	r3 := httptest.NewRequest("POST", "/v1/keys/verify", bytes.NewReader([]byte(`{"key":"EVIL"}`)))
	r3.Header.Set("X-Service-Auth", ComputeServiceSignature("secret", "POST", "/v1/keys/verify", body, ts))
	if VerifyServiceRequest(r3, "secret") {
		t.Fatal("hmac mode must reject a tampered body")
	}

	// Different path fails.
	r4 := httptest.NewRequest("POST", "/v1/other", bytes.NewReader(body))
	r4.Header.Set("X-Service-Auth", ComputeServiceSignature("secret", "POST", "/v1/keys/verify", body, ts))
	if VerifyServiceRequest(r4, "secret") {
		t.Fatal("hmac mode must reject a replay against another path")
	}

	// Expired timestamp fails.
	r5 := httptest.NewRequest("POST", "/v1/keys/verify", bytes.NewReader(body))
	r5.Header.Set("X-Service-Auth", ComputeServiceSignature("secret", "POST", "/v1/keys/verify", body, ts-3600))
	if VerifyServiceRequest(r5, "secret") {
		t.Fatal("hmac mode must reject an expired signature")
	}
}
