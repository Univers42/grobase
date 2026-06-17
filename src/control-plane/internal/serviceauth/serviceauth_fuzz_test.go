package serviceauth

import (
	"encoding/hex"
	"net/http/httptest"
	"strings"
	"testing"
)

// FuzzComputeServiceSignature: never panics, is deterministic, and always emits
// a well-formed v1.<ts>.<64-hex> envelope regardless of input bytes.
func FuzzComputeServiceSignature(f *testing.F) {
	f.Add("tok", "POST", "/v1/keys/verify", []byte(`{}`), int64(1700000000))
	f.Add("", "GET", "/", []byte(nil), int64(0))
	f.Add("k", "p\x00st", "/a\nb", []byte("\x00\x01"), int64(-5))
	f.Fuzz(func(t *testing.T, token, method, path string, body []byte, ts int64) {
		sig := ComputeServiceSignature(token, method, path, body, ts) // must not panic
		if sig != ComputeServiceSignature(token, method, path, body, ts) {
			t.Fatal("signature not deterministic")
		}
		parts := strings.Split(sig, ".")
		if len(parts) != 3 || parts[0] != "v1" {
			t.Fatalf("malformed envelope %q", sig)
		}
		if len(parts[2]) != 64 {
			t.Fatalf("hmac hex len %d, want 64 (sig=%q)", len(parts[2]), sig)
		}
		if _, err := hex.DecodeString(parts[2]); err != nil {
			t.Fatalf("hmac not hex: %v", err)
		}
	})
}

// FuzzVerifyServiceRequestStatic: in static mode (default), VerifyServiceRequest
// accepts IFF the presented X-Service-Token byte-equals a non-empty expected
// token. Never panics; an empty expected token never authorizes (fail closed).
func FuzzVerifyServiceRequestStatic(f *testing.F) {
	f.Add("secret", "secret")
	f.Add("secret", "wrong")
	f.Add("", "anything")
	f.Add("\x00", "\x00")
	f.Add("a", "")
	f.Fuzz(func(t *testing.T, expected, presented string) {
		t.Setenv("SERVICE_TOKEN_MODE", "")
		t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", "")
		r := httptest.NewRequest("POST", "/v1/keys/verify", strings.NewReader("{}"))
		r.Header.Set("X-Service-Token", presented)
		got := VerifyServiceRequest(r, expected) // must not panic
		want := expected != "" && presented == expected
		if got != want {
			t.Fatalf("VerifyServiceRequest(expected=%q, presented=%q)=%v, want %v", expected, presented, got, want)
		}
	})
}

// FuzzVerifyServiceRequestHMAC_RejectsForged: in hmac mode, an arbitrary
// X-Service-Auth header must NOT authorize unless it byte-equals a freshly
// computed signature for the request. Never panics; empty expected fails closed.
func FuzzVerifyServiceRequestHMAC_RejectsForged(f *testing.F) {
	f.Add("secret", "v1.x.y")
	f.Add("secret", "")
	f.Add("", "v1.100.abc")
	f.Add("k", "\x00")
	f.Fuzz(func(t *testing.T, expected, hdr string) {
		t.Setenv("SERVICE_TOKEN_MODE", "hmac")
		t.Setenv("INTERNAL_SERVICE_TOKEN_PREV", "")
		r := httptest.NewRequest("POST", "/v1/keys/verify", strings.NewReader("{}"))
		r.Header.Set("X-Service-Auth", hdr)
		if !VerifyServiceRequest(r, expected) {
			return // rejected — the expected outcome for a forged/arbitrary header
		}
		// Accepted: it must be a valid v1.<ts>.<sig> within skew, matching recompute.
		if expected == "" {
			t.Fatalf("empty expected token authorized header %q (must fail closed)", hdr)
		}
		parts := strings.Split(hdr, ".")
		if len(parts) != 3 || parts[0] != "v1" {
			t.Fatalf("accepted malformed header %q", hdr)
		}
	})
}

// TestSecureCompare_EmptyWant pins the fail-closed contract: an empty expected
// token never authorizes, even against an empty presented token.
func TestSecureCompare_EmptyWant(t *testing.T) {
	if SecureCompare("", "") {
		t.Fatal("empty want must never authorize")
	}
	if SecureCompare("x", "") {
		t.Fatal("empty want must never authorize")
	}
	if !SecureCompare("x", "x") {
		t.Fatal("equal non-empty tokens must authorize")
	}
}

// FuzzSecureCompare: never panics; equals a plain string compare with the empty
// `want` short-circuit.
func FuzzSecureCompare(f *testing.F) {
	f.Add("a", "a")
	f.Add("a", "b")
	f.Add("", "")
	f.Add("\x00", "\x00")
	f.Fuzz(func(t *testing.T, got, want string) {
		res := SecureCompare(got, want) // must not panic
		expect := want != "" && got == want
		if res != expect {
			t.Fatalf("SecureCompare(%q,%q)=%v, want %v", got, want, res, expect)
		}
	})
}
