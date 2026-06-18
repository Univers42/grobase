package backup

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// TestGuardIsolation pins the MVP isolation allow-list: only schema_per_tenant
// passes; everything else (including db_per_tenant, the deferred models, and
// garbage) returns ErrIsolationDeferred. This is the gate that stops the service
// advertising support it can't deliver, so each rejection is load-bearing.
func TestGuardIsolation(t *testing.T) {
	cases := []struct {
		iso     string
		wantErr bool
	}{
		{"schema_per_tenant", false},
		{"db_per_tenant", true},
		{"shared_rls", true},
		{"tenant_owned", true},
		{"", true},
		{"nonsense", true},
	}
	for _, tc := range cases {
		t.Run(tc.iso, func(t *testing.T) {
			err := guardIsolation(tc.iso)
			if tc.wantErr {
				if !errors.Is(err, ErrIsolationDeferred) {
					t.Fatalf("guardIsolation(%q) = %v, want ErrIsolationDeferred", tc.iso, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("guardIsolation(%q) = %v, want nil", tc.iso, err)
			}
		})
	}
}

// makeArtifact concatenates per-table COPY bodies, then the sentinel + JSON
// manifest footer, exactly as writeManifest does — so splitArtifact can re-split
// it. It returns the full artifact bytes and the manifest.
func makeArtifact(t *testing.T, tables []tableExtract, bodies ...string) ([]byte, manifest) {
	t.Helper()
	var buf bytes.Buffer
	for _, b := range bodies {
		buf.WriteString(b)
	}
	m := manifest{Schema: "tenant_x", Engine: "postgresql", Tables: tables}
	if err := writeManifest(&buf, m); err != nil {
		t.Fatalf("writeManifest: %v", err)
	}
	return buf.Bytes(), m
}

// TestSplitArtifactRoundTrip asserts writeManifest -> splitArtifact is a faithful
// round trip: the body is everything before the sentinel and the manifest parses
// back with its table slices intact.
func TestSplitArtifactRoundTrip(t *testing.T) {
	tables := []tableExtract{
		{Table: "users", Bytes: 6, Rows: 2},
		{Table: "orders", Bytes: 4, Rows: 1},
	}
	artifact, want := makeArtifact(t, tables, "USERS\n", "ORD\n")

	body, got, err := splitArtifact(bytes.NewReader(artifact))
	if err != nil {
		t.Fatalf("splitArtifact: %v", err)
	}
	if string(body) != "USERS\nORD\n" {
		t.Fatalf("body = %q, want %q", string(body), "USERS\nORD\n")
	}
	if got.Schema != want.Schema || got.Engine != want.Engine {
		t.Fatalf("manifest header = %+v, want %+v", got, want)
	}
	if len(got.Tables) != 2 || got.Tables[0].Table != "users" || got.Tables[1].Bytes != 4 {
		t.Fatalf("manifest tables = %+v", got.Tables)
	}
}

// TestSplitArtifactMissingFooter asserts an artifact with no sentinel is rejected
// (a corrupt/truncated artifact must not parse as an empty manifest).
func TestSplitArtifactMissingFooter(t *testing.T) {
	_, _, err := splitArtifact(strings.NewReader("just a copy body, no footer"))
	if err == nil {
		t.Fatalf("splitArtifact(no footer) = nil error")
	}
	if !strings.Contains(err.Error(), "missing manifest footer") {
		t.Fatalf("error = %v, want missing manifest footer", err)
	}
}

// TestSplitArtifactBadManifestJSON asserts a present-but-invalid JSON footer is
// reported as a parse error, not silently dropped.
func TestSplitArtifactBadManifestJSON(t *testing.T) {
	bad := []byte("body" + manifestSentinel + "{not json")
	_, _, err := splitArtifact(bytes.NewReader(bad))
	if err == nil {
		t.Fatalf("splitArtifact(bad json) = nil error")
	}
	if !strings.Contains(err.Error(), "parse manifest") {
		t.Fatalf("error = %v, want parse manifest", err)
	}
}

// TestCountingWriter asserts the writer forwards bytes and tallies the count
// across multiple writes (used to record per-table slice lengths un-buffered).
func TestCountingWriter(t *testing.T) {
	var sink bytes.Buffer
	cw := &countingWriter{w: &sink}
	for _, chunk := range []string{"abc", "", "defgh"} {
		n, err := cw.Write([]byte(chunk))
		if err != nil {
			t.Fatalf("Write(%q): %v", chunk, err)
		}
		if n != len(chunk) {
			t.Fatalf("Write(%q) n = %d, want %d", chunk, n, len(chunk))
		}
	}
	if cw.n != 8 {
		t.Fatalf("counted %d bytes, want 8", cw.n)
	}
	if sink.String() != "abcdefgh" {
		t.Fatalf("forwarded %q, want abcdefgh", sink.String())
	}
}
