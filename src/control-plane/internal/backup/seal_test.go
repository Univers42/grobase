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
	if !bytes.HasPrefix(sealed, []byte("age-encryption.org/v1\n")) || bytes.Contains(sealed, []byte("tenant-secret-row")) {
		t.Fatalf("artifact is not sealed: %q", sealed[:40])
	}
	got, err := sl.open(bytes.NewReader(sealed), true)
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
	if _, err := sl.open(bytes.NewReader(buf.Bytes()), true); err == nil {
		t.Fatal("a truncated sealed artifact opened — the partial stream was authenticated")
	}
}

// TestOpenPolicy covers the plaintext and missing-identity refusals, and that
// the seal state comes from the ledger: a plaintext row shaped like the age
// header still restores as plaintext.
func TestOpenPolicy(t *testing.T) {
	id, rcpt := newKeys(t)
	full := Sealer{recipients: []age.Recipient{rcpt}, identities: []age.Identity{id}}
	optOut := full
	optOut.allowPlaintext = true
	plain := []byte("1\trow\n")
	headerRow := []byte("age-encryption.org/v1\n")
	sealed := sealWith(t, Sealer{recipients: []age.Recipient{rcpt}}, plain)
	cases := []struct {
		name   string
		sl     Sealer
		in     []byte
		sealed bool
		want   error
		out    []byte
	}{
		{"parity reads plaintext", Sealer{}, plain, false, nil, plain},
		{"parity reads a header-shaped row", Sealer{}, headerRow, false, nil, headerRow},
		{"sealing refuses plaintext", full, plain, false, ErrPlaintextArtifact, nil},
		{"opt-out reads plaintext", optOut, plain, false, nil, plain},
		{"opt-out reads a header-shaped row", optOut, headerRow, false, nil, headerRow},
		{"no identity refuses sealed", Sealer{}, sealed, true, ErrArtifactSealed, nil},
		{"identity-only reads sealed", Sealer{identities: []age.Identity{id}}, sealed, true, nil, plain},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := tc.sl.open(bytes.NewReader(tc.in), tc.sealed)
			if !errors.Is(err, tc.want) {
				t.Fatalf("open err = %v, want %v", err, tc.want)
			}
			if tc.want == nil && !bytes.Equal(got, tc.out) {
				t.Fatalf("open = %q, want %q", got, tc.out)
			}
		})
	}
}

// TestArtifactKey: only a sealed artifact carries the suffix the ledger reads.
func TestArtifactKey(t *testing.T) {
	if got := artifactKey("t", "b", false); got != "t/b" {
		t.Fatalf("plaintext key = %q", got)
	}
	if got := artifactKey("t", "b", true); got != "t/b.age" || !(restoreRow{location: "/x/" + got}).sealed() {
		t.Fatalf("sealed key = %q", got)
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
// world-readable file, a non-matching identity, recipients without an identity,
// an identity that opens the whole-cluster backups (any separator) or a
// post-quantum + classic recipient mix refuse to boot.
func TestNewSealerFromEnv(t *testing.T) {
	id, rcpt := newKeys(t)
	other, _ := newKeys(t)
	pq, err := age.GenerateHybridIdentity()
	if err != nil {
		t.Fatal(err)
	}
	pub := rcpt.(*age.X25519Recipient).String()
	otherPub := other.Recipient().String()
	good := writeIdentityFile(t, id, 0o600)
	cases := []struct {
		name, recipients, idFile, cluster, wantErr string
	}{
		{"unset", "", "", "", ""},
		{"matching", pub, good, "", ""},
		{"matching among two", otherPub + ", " + pub, good, "", ""},
		{"tab separated", otherPub + "\t" + pub, good, "", ""},
		{"cluster uses another key", pub, good, otherPub, ""},
		{"bad recipient", "age1bogus", good, "", "TENANT_BACKUP_AGE_RECIPIENTS"},
		{"world readable", pub, writeIdentityFile(t, id, 0o644), "", "want 0600"},
		{"no match", pub, writeIdentityFile(t, other, 0o600), "", "matches"},
		{"recipients without identity", pub, "", "", "matches"},
		{"identity opens cluster backups", pub, good, otherPub + "\t" + pub, "BACKUP_AGE_RECIPIENTS"},
		{"identity-only opens cluster backups", "", good, pub, "BACKUP_AGE_RECIPIENTS"},
		{"post-quantum and classic mix", pq.Recipient().String() + "," + pub, good, "", "sealed to together"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("TENANT_BACKUP_AGE_RECIPIENTS", tc.recipients)
			t.Setenv("TENANT_BACKUP_AGE_IDENTITY_FILE", tc.idFile)
			t.Setenv("BACKUP_AGE_RECIPIENTS", tc.cluster)
			sl, err := NewSealerFromEnv()
			if tc.wantErr == "" && err != nil {
				t.Fatalf("NewSealerFromEnv = %v, want success", err)
			}
			if tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)) {
				t.Fatalf("NewSealerFromEnv err = %v, want it to mention %q", err, tc.wantErr)
			}
			if tc.name == "unset" && (sl.sealing() || len(sl.identities) != 0) {
				t.Fatal("unset env produced a sealing sealer")
			}
		})
	}
}
