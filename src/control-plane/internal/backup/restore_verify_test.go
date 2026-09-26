package backup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"testing"

	"filippo.io/age"
	"go.uber.org/goleak"
)

// shaHex is the lower-hex sha256 of b, as the ledger stores it.
func shaHex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// sealingService returns a Service over store that seals to a fresh key.
func sealingService(t *testing.T, store ArtifactStore) *Service {
	t.Helper()
	id, rcpt := newKeys(t)
	return &Service{store: store, seal: Sealer{recipients: []age.Recipient{rcpt}, identities: []age.Identity{id}}}
}

// TestFetchVerified: the ledger sha256 of the STORED bytes gates every restore —
// missing, mismatched and swapped artifacts are refused; the match opens.
func TestFetchVerified(t *testing.T) {
	defer goleak.VerifyNone(t)
	store := newFakeStore()
	s := sealingService(t, store)
	own := sealWith(t, s.seal, []byte("own-rows"))
	other := sealWith(t, s.seal, []byte("another-tenant-rows"))
	cases := []struct {
		name    string
		content []byte
		want    string
		err     error
	}{
		{"match", own, shaHex(own), nil},
		{"no ledger sha", own, "", ErrArtifactUnverified},
		{"tampered", append(bytes.Clone(own[:len(own)-1]), own[len(own)-1]^1), shaHex(own), nil},
		{"swapped for another sealed artifact", other, shaHex(own), ErrArtifactIntegrity},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store.content = tc.content
			got, err := s.fetchVerified(context.Background(), "k", tc.want)
			switch {
			case tc.name == "tampered":
				if err == nil {
					t.Fatal("a tampered sealed artifact was accepted")
				}
			case !errors.Is(err, tc.err):
				t.Fatalf("fetchVerified err = %v, want %v", err, tc.err)
			case tc.err == nil && string(got) != "own-rows":
				t.Fatalf("fetchVerified = %q, want own-rows", got)
			}
		})
	}
}

// TestFetchVerifiedEarlyRefusalNoLeak: a refusal before the artifact is read
// through must still unblock and await the download goroutine.
func TestFetchVerifiedEarlyRefusalNoLeak(t *testing.T) {
	defer goleak.VerifyNone(t)
	store := newFakeStore()
	store.content = bytes.Repeat([]byte("p"), 1<<20)
	s := sealingService(t, store)
	if _, err := s.fetchVerified(context.Background(), "k", shaHex(store.content)); !errors.Is(err, ErrPlaintextArtifact) {
		t.Fatalf("fetchVerified = %v, want ErrPlaintextArtifact", err)
	}
}

// earlyStore fails Upload without reading, or (lenient) reads to the first
// error and reports success anyway.
type earlyStore struct{ lenient bool }

func (e earlyStore) Upload(_ context.Context, _ string, r io.Reader) (string, int64, string, error) {
	if e.lenient {
		_, _ = io.Copy(io.Discard, r)
		return "loc", 1, "sha", nil
	}
	return "", 0, "", errors.New("store unavailable")
}

func (earlyStore) Download(context.Context, string, io.Writer) error { return nil }
func (earlyStore) Delete(context.Context, string) error              { return nil }

// TestExtractToPipeHygiene: an Upload that returns without reading unblocks the
// sealing writer (no leak), and a source failure fails the backup even when the
// store swallows the read error.
func TestExtractToPipeHygiene(t *testing.T) {
	defer goleak.VerifyNone(t)
	s := sealingService(t, earlyStore{})
	if _, _, _, err := s.extractTo(context.Background(), "shared_rls", "t", "", "t/b"); err == nil || err.Error() != "store unavailable" {
		t.Fatalf("extractTo = %v, want the store error", err)
	}
	s = sealingService(t, earlyStore{lenient: true})
	if _, _, _, err := s.extractTo(context.Background(), "shared_rls", "t", "", "t/b"); !errors.Is(err, ErrIsolationDeferred) {
		t.Fatalf("extractTo = %v, want the source error despite a lenient store", err)
	}
}
