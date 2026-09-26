package backup

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"filippo.io/age"
)

// newKeys returns a fresh X25519 identity and its recipient.
func newKeys(t *testing.T) (*age.X25519Identity, age.Recipient) {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatal(err)
	}
	return id, id.Recipient()
}

// sealWith returns what writeTo produces for payload under sl.
func sealWith(t *testing.T, sl Sealer, payload []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := sl.writeTo(&buf, func(w io.Writer) error { _, err := w.Write(payload); return err }); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// TestSealRoundTrip: a sealed artifact starts with the age header, carries no
// plaintext, and opens back to the exact payload.
func TestSealRoundTrip(t *testing.T) {
	id, rcpt := newKeys(t)
	sl := Sealer{recipients: []age.Recipient{rcpt}, identities: []age.Identity{id}}
	payload := []byte("1\ttenant-secret-row\n")
	sealed := sealWith(t, sl, payload)
	if !bytes.HasPrefix(sealed, []byte(ageHeader)) || bytes.Contains(sealed, []byte("tenant-secret-row")) {
		t.Fatalf("artifact is not sealed: %q", sealed[:40])
	}
	got, err := sl.open(bytes.NewReader(sealed))
	if err != nil || !bytes.Equal(got, payload) {
		t.Fatalf("open = %q, %v; want the payload", got, err)
	}
}

// TestSealFillErrorNotAuthenticated: when the source fails mid-stream the age
// stream is left unfinished, so the partial artifact never decrypts.
func TestSealFillErrorNotAuthenticated(t *testing.T) {
	id, rcpt := newKeys(t)
	sl := Sealer{recipients: []age.Recipient{rcpt}, identities: []age.Identity{id}}
	var buf bytes.Buffer
	boom := errors.New("source died")
	err := sl.writeTo(&buf, func(w io.Writer) error {
		_, _ = w.Write(bytes.Repeat([]byte("x"), 200<<10))
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("writeTo = %v, want the source error", err)
	}
	if _, err := sl.open(bytes.NewReader(buf.Bytes())); err == nil {
		t.Fatal("a truncated sealed artifact opened — the partial stream was authenticated")
	}
}

// TestOpenPolicy covers the plaintext and missing-identity refusals.
func TestOpenPolicy(t *testing.T) {
	id, rcpt := newKeys(t)
	plain := []byte("1\trow\n")
	sealed := sealWith(t, Sealer{recipients: []age.Recipient{rcpt}}, plain)
	cases := []struct {
		name string
		sl   Sealer
		in   []byte
		want error
	}{
		{"parity reads plaintext", Sealer{}, plain, nil},
		{"sealing refuses plaintext", Sealer{recipients: []age.Recipient{rcpt}, identities: []age.Identity{id}}, plain, ErrPlaintextArtifact},
		{"opt-out reads plaintext", Sealer{recipients: []age.Recipient{rcpt}, identities: []age.Identity{id}, allowPlaintext: true}, plain, nil},
		{"no identity refuses sealed", Sealer{}, sealed, ErrArtifactSealed},
		{"identity-only reads sealed", Sealer{identities: []age.Identity{id}}, sealed, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := tc.sl.open(bytes.NewReader(tc.in))
			if !errors.Is(err, tc.want) {
				t.Fatalf("open err = %v, want %v", err, tc.want)
			}
			if tc.want == nil && !bytes.Equal(got, plain) {
				t.Fatalf("open = %q, want %q", got, plain)
			}
		})
	}
}

// writeIdentityFile writes id to a file of the given mode and returns its path.
func writeIdentityFile(t *testing.T, id *age.X25519Identity, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "id.key")
	if err := os.WriteFile(p, []byte(id.String()+"\n"), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, mode); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestNewSealerFromEnv: unset is parity; a matching 0600 identity boots; a
// world-readable file, a non-matching identity or recipients without an
// identity refuse to boot.
func TestNewSealerFromEnv(t *testing.T) {
	id, rcpt := newKeys(t)
	other, _ := newKeys(t)
	pub := rcpt.(*age.X25519Recipient).String()
	otherPub := other.Recipient().String()
	cases := []struct {
		name, recipients, idFile, wantErr string
	}{
		{"unset", "", "", ""},
		{"matching", pub, writeIdentityFile(t, id, 0o600), ""},
		{"matching among two", otherPub + ", " + pub, writeIdentityFile(t, id, 0o600), ""},
		{"bad recipient", "age1bogus", writeIdentityFile(t, id, 0o600), "TENANT_BACKUP_AGE_RECIPIENTS"},
		{"world readable", pub, writeIdentityFile(t, id, 0o644), "want 0600"},
		{"no match", pub, writeIdentityFile(t, other, 0o600), "matches"},
		{"recipients without identity", pub, "", "matches"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("TENANT_BACKUP_AGE_RECIPIENTS", tc.recipients)
			t.Setenv("TENANT_BACKUP_AGE_IDENTITY_FILE", tc.idFile)
			sl, err := NewSealerFromEnv()
			if tc.wantErr == "" && err != nil {
				t.Fatalf("NewSealerFromEnv = %v, want success", err)
			}
			if tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)) {
				t.Fatalf("NewSealerFromEnv err = %v, want it to mention %q", err, tc.wantErr)
			}
			if tc.name == "unset" && (len(sl.recipients) != 0 || len(sl.identities) != 0) {
				t.Fatal("unset env produced a sealing sealer")
			}
		})
	}
}
