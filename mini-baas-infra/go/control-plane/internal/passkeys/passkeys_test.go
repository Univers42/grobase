package passkeys

import (
	"encoding/base64"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/golang-jwt/jwt/v5"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// TestSessionStore_SingleUse proves a challenge is consumed exactly once: a
// second take of the same id fails. This is the anti-replay backstop for the
// finish path (a replayed challenge id cannot complete a ceremony).
func TestSessionStore_SingleUse(t *testing.T) {
	s := newSessionStore()
	id, err := s.put(pending{userID: "u1"})
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	if _, ok := s.take(id); !ok {
		t.Fatal("first take should succeed")
	}
	if _, ok := s.take(id); ok {
		t.Fatal("second take of the same challenge must fail (single-use)")
	}
}

// TestSessionStore_TTLExpiry proves an aged challenge cannot be taken — the
// finish path therefore rejects a stale begin (one of the gate's reject vectors).
func TestSessionStore_TTLExpiry(t *testing.T) {
	base := time.Now()
	s := newSessionStore()
	s.now = func() time.Time { return base }
	id, err := s.put(pending{userID: "u1"})
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	// Advance past the TTL.
	s.now = func() time.Time { return base.Add(challengeTTL + time.Second) }
	if _, ok := s.take(id); ok {
		t.Fatal("an expired challenge must not be takeable")
	}
}

// TestSessionStore_UnknownID proves a forged challenge id (never issued) fails.
func TestSessionStore_UnknownID(t *testing.T) {
	s := newSessionStore()
	if _, ok := s.take("never-issued"); ok {
		t.Fatal("an unknown challenge id must fail")
	}
}

// TestSessionMinter_RoundTrip proves the minted session JWT verifies under the
// EXISTING tenants.JWTVerifier with the same secret — a passkey login yields a
// session interchangeable with a password login.
func TestSessionMinter_RoundTrip(t *testing.T) {
	const secret = "dev-test-jwt-secret-please-do-not-use-in-prod"
	m := NewSessionMinter(secret, "", time.Hour)
	sess, err := m.Mint("11111111-2222-3333-4444-555555555555", "user@example.com")
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	if sess.TokenType != "bearer" || sess.AccessToken == "" {
		t.Fatalf("unexpected session: %+v", sess)
	}
	v, err := tenants.NewJWTVerifier(secret, "")
	if err != nil {
		t.Fatalf("verifier: %v", err)
	}
	id, err := v.Verify(sess.AccessToken)
	if err != nil {
		t.Fatalf("the minted token must verify under the control-plane verifier: %v", err)
	}
	if id.UserID != "11111111-2222-3333-4444-555555555555" {
		t.Errorf("sub mismatch: %q", id.UserID)
	}
	if id.Email != "user@example.com" {
		t.Errorf("email mismatch: %q", id.Email)
	}
}

// TestSessionMinter_WrongSecretRejected proves a token minted under secret A
// does NOT verify under secret B — the session's authority is the shared secret.
func TestSessionMinter_WrongSecretRejected(t *testing.T) {
	m := NewSessionMinter("secret-A", "", time.Hour)
	sess, _ := m.Mint("u1", "")
	v, _ := tenants.NewJWTVerifier("secret-B", "")
	if _, err := v.Verify(sess.AccessToken); err == nil {
		t.Fatal("a token minted under a different secret must not verify")
	}
}

// TestSessionMinter_Issuer proves the iss claim is stamped + verified when set.
func TestSessionMinter_Issuer(t *testing.T) {
	const secret, iss = "s", "https://grobase.example.com"
	m := NewSessionMinter(secret, iss, time.Hour)
	sess, _ := m.Mint("u1", "")
	v, _ := tenants.NewJWTVerifier(secret, iss)
	if _, err := v.Verify(sess.AccessToken); err != nil {
		t.Fatalf("issuer-bound token should verify with matching issuer: %v", err)
	}
	// And a wrong issuer is rejected.
	vWrong, _ := tenants.NewJWTVerifier(secret, "https://attacker.example.com")
	if _, err := vWrong.Verify(sess.AccessToken); err == nil {
		t.Fatal("a token must not verify against a different issuer")
	}
	// sanity: the unsigned-alg / none class is closed by the verifier itself.
	_ = jwt.SigningMethodHS256
}

// TestCredentialRoundTrip proves encode→decode preserves the credential bytes,
// so a stored credential reconstructs exactly the webauthn.Credential the login
// ceremony verifies against. A mangled round-trip would silently break login.
func TestCredentialRoundTrip(t *testing.T) {
	orig := &webauthn.Credential{
		ID:        []byte{0x01, 0x02, 0x03, 0xff, 0xfe},
		PublicKey: []byte("a-cose-public-key-blob"),
		Transport: []protocol.AuthenticatorTransport{protocol.USB, protocol.Internal},
		Authenticator: webauthn.Authenticator{
			AAGUID:    []byte{0xaa, 0xbb, 0xcc, 0xdd},
			SignCount: 7,
		},
	}
	sc := encodeCredential(orig, "tenant-x", "user-y", "user@example.com")
	if sc.TenantID != "tenant-x" || sc.UserID != "user-y" {
		t.Fatalf("scope not carried: %+v", sc)
	}
	if sc.SignCount != 7 {
		t.Fatalf("sign_count not carried: %d", sc.SignCount)
	}
	back, err := decodeCredential(sc)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if string(back.ID) != string(orig.ID) {
		t.Errorf("credential id round-trip mismatch")
	}
	if string(back.PublicKey) != string(orig.PublicKey) {
		t.Errorf("public key round-trip mismatch")
	}
	if string(back.Authenticator.AAGUID) != string(orig.Authenticator.AAGUID) {
		t.Errorf("aaguid round-trip mismatch")
	}
	if back.Authenticator.SignCount != 7 {
		t.Errorf("sign_count round-trip mismatch: %d", back.Authenticator.SignCount)
	}
	// the stored credential id must be base64url-decodable (the login lookup key).
	if _, err := base64.RawURLEncoding.DecodeString(sc.CredentialID); err != nil {
		t.Errorf("stored credential id not base64url: %v", err)
	}
}
