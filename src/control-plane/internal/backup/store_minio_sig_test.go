package backup

import (
	"context"
	"encoding/hex"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// TestHMACSHA256RFC4231 pins hmacSHA256 against RFC 4231 Test Case 1, an external
// known-answer vector (key=0x0b×20, data="Hi There"). This proves the primitive
// the whole SigV4 chain rests on is correct, independent of our own code.
func TestHMACSHA256RFC4231(t *testing.T) {
	key := []byte{
		0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
		0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b, 0x0b,
	}
	const want = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
	got := hex.EncodeToString(hmacSHA256(key, []byte("Hi There")))
	if got != want {
		t.Fatalf("hmacSHA256(RFC4231 case1) = %s, want %s", got, want)
	}
}

// TestHMACSHA256Determinism asserts the MAC is a pure function: same inputs ->
// same output, and a one-bit change in the data changes the output.
func TestHMACSHA256Determinism(t *testing.T) {
	a := hmacSHA256([]byte("k"), []byte("payload"))
	b := hmacSHA256([]byte("k"), []byte("payload"))
	if hex.EncodeToString(a) != hex.EncodeToString(b) {
		t.Fatalf("hmacSHA256 not deterministic")
	}
	c := hmacSHA256([]byte("k"), []byte("payloaD"))
	if hex.EncodeToString(a) == hex.EncodeToString(c) {
		t.Fatalf("hmacSHA256 collided on different data")
	}
}

// TestSigV4Key pins the AWS SigV4 signing-key derivation chain to its
// deterministic output for fixed inputs, then asserts each link of the
// HMAC chain is load-bearing (changing secret/date/region/service all change
// the key). The pinned value is the exact bytes this code emits — a regression
// in the derivation order or any "AWS4"/"aws4_request" literal flips it.
func TestSigV4Key(t *testing.T) {
	const (
		secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
		date   = "20150830"
		region = "us-east-1"
		svc    = "iam"
		want   = "2c94c0cf5378ada6887f09bb697df8fc0affdb34ba1cdd5bda32b664bd55b73c"
	)
	got := hex.EncodeToString(sigV4Key(secret, date, region, svc))
	if got != want {
		t.Fatalf("sigV4Key = %s, want %s", got, want)
	}

	base := hex.EncodeToString(sigV4Key(secret, date, region, svc))
	cases := []struct {
		name                            string
		secret, date, region, service string
	}{
		{"diff secret", "other", date, region, svc},
		{"diff date", secret, "20240101", region, svc},
		{"diff region", secret, date, "eu-west-1", svc},
		{"diff service", secret, date, region, "s3"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if hex.EncodeToString(sigV4Key(tc.secret, tc.date, tc.region, tc.service)) == base {
				t.Fatalf("sigV4Key ignored %s — input is not load-bearing", tc.name)
			}
		})
	}
}

// minioForSig builds a MinIOStore wired for signature tests without touching
// the network (no selfCheck), so authHeader/signedRequest are exercised in
// isolation.
func minioForSig() *MinIOStore {
	return &MinIOStore{
		client:   &http.Client{},
		endpoint: "minio:9000",
		secure:   false,
		region:   "us-east-1",
		bucket:   "baas",
		prefix:   "backups/",
		access:   "AKIDEXAMPLE",
		secret:   "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
	}
}

// TestAuthHeaderShape asserts the SigV4 Authorization header has the exact
// SigV4 structure (algorithm, Credential scope, SignedHeaders) and a 64-hex
// signature, and that the signature is a deterministic function of the canonical
// inputs — two identical inputs sign identically.
func TestAuthHeaderShape(t *testing.T) {
	s := minioForSig()
	u, _ := url.Parse(s.objectURL("tenant-1/abc"))
	in := sigInput{
		method:      http.MethodPut,
		u:           u,
		amzDate:     "20240101T000000Z",
		dateStamp:   "20240101",
		payloadHash: strings.Repeat("0", 64),
	}
	h := s.authHeader(in)

	if !strings.HasPrefix(h, "AWS4-HMAC-SHA256 ") {
		t.Fatalf("auth header missing algorithm: %q", h)
	}
	wantCred := "Credential=AKIDEXAMPLE/20240101/us-east-1/s3/aws4_request"
	if !strings.Contains(h, wantCred) {
		t.Fatalf("auth header missing credential scope %q in %q", wantCred, h)
	}
	if !strings.Contains(h, "SignedHeaders=host;x-amz-content-sha256;x-amz-date") {
		t.Fatalf("auth header wrong SignedHeaders: %q", h)
	}
	sig := signatureOf(t, h)
	if len(sig) != 64 {
		t.Fatalf("signature not 64 hex chars: %q", sig)
	}
	if _, err := hex.DecodeString(sig); err != nil {
		t.Fatalf("signature not hex: %v", err)
	}
	if again := signatureOf(t, s.authHeader(in)); again != sig {
		t.Fatalf("authHeader not deterministic: %s vs %s", sig, again)
	}
}

// TestAuthHeaderSensitivity asserts the signature changes when the method, the
// path, the amz date, or the payload hash change — proving each is folded into
// the canonical request (a silent drop would be a signing bug a server rejects).
func TestAuthHeaderSensitivity(t *testing.T) {
	s := minioForSig()
	u, _ := url.Parse(s.objectURL("tenant-1/abc"))
	uOther, _ := url.Parse(s.objectURL("tenant-1/xyz"))
	base := sigInput{
		method:      http.MethodPut,
		u:           u,
		amzDate:     "20240101T000000Z",
		dateStamp:   "20240101",
		payloadHash: strings.Repeat("0", 64),
	}
	baseSig := signatureOf(t, s.authHeader(base))

	mutate := func(f func(*sigInput)) string {
		in := base
		f(&in)
		return signatureOf(t, s.authHeader(in))
	}
	cases := map[string]func(*sigInput){
		"method":  func(in *sigInput) { in.method = http.MethodGet },
		"path":    func(in *sigInput) { in.u = uOther },
		"amzDate": func(in *sigInput) { in.amzDate = "20240102T000000Z" },
		"payload": func(in *sigInput) { in.payloadHash = strings.Repeat("a", 64) },
	}
	for name, f := range cases {
		t.Run(name, func(t *testing.T) {
			if mutate(f) == baseSig {
				t.Fatalf("signature ignored %s change — not in canonical request", name)
			}
		})
	}
}

// TestSignedRequestHeaders asserts signedRequest stamps the four SigV4 headers
// (Host, X-Amz-Date, X-Amz-Content-Sha256, Authorization) onto the *http.Request
// with the right method and URL, without performing any network I/O.
func TestSignedRequestHeaders(t *testing.T) {
	s := minioForSig()
	const payload = "deadbeef"
	req, err := s.signedRequest(context.Background(), http.MethodPut, "t/b", []byte("body"), payload)
	if err != nil {
		t.Fatalf("signedRequest: %v", err)
	}
	if req.Method != http.MethodPut {
		t.Fatalf("method = %s, want PUT", req.Method)
	}
	if got := req.Header.Get("X-Amz-Content-Sha256"); got != payload {
		t.Fatalf("payload hash header = %q, want %q", got, payload)
	}
	if got := req.Header.Get("Host"); got != "minio:9000" {
		t.Fatalf("host header = %q, want minio:9000", got)
	}
	if req.Header.Get("X-Amz-Date") == "" {
		t.Fatalf("missing X-Amz-Date header")
	}
	if !strings.HasPrefix(req.Header.Get("Authorization"), "AWS4-HMAC-SHA256 ") {
		t.Fatalf("missing/invalid Authorization header: %q", req.Header.Get("Authorization"))
	}
}

// signatureOf extracts the hex signature from a SigV4 Authorization header value.
func signatureOf(t *testing.T, h string) string {
	t.Helper()
	const marker = "Signature="
	i := strings.Index(h, marker)
	if i < 0 {
		t.Fatalf("no Signature= in %q", h)
	}
	return h[i+len(marker):]
}
