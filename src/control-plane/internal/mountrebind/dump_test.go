package mountrebind

import (
	"bufio"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
)

const (
	sourceKey = "source-key-0123456789abcdef"
	targetKey = "target-key-fedcba9876543210"
	otherKey  = "unrelated-key-000000000000"
	header    = "COPY public.tenant_databases (id, tenant_id, engine, name, connection_enc, connection_iv, connection_tag, connection_salt, created_at) FROM stdin;\n"
)

func sealedRow(t *testing.T, key, id, engine, dsn string) string {
	t.Helper()
	enc, err := adapterregistry.NewEncryptor(key)
	if err != nil {
		t.Fatal(err)
	}
	p, err := enc.Encrypt(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cols := []string{id, "agency", engine, "n"}
	for _, b := range [][]byte{p.Encrypted, p.IV, p.Tag, p.Salt} {
		cols = append(cols, `\\x`+hex.EncodeToString(b))
	}
	return strings.Join(append(cols, "2026-01-01"), "\t") + "\n"
}

func openRow(t *testing.T, key, line string) string {
	t.Helper()
	enc, err := adapterregistry.NewEncryptor(key)
	if err != nil {
		t.Fatal(err)
	}
	p, ok := payloadOf(strings.Split(strings.TrimSuffix(line, "\n"), "\t"), columnIndex(header))
	if !ok {
		t.Fatalf("row has no payload: %q", line)
	}
	dsn, err := enc.Decrypt(p)
	if err != nil {
		t.Fatalf("target key does not open the row: %v", err)
	}
	return dsn
}

func TestRewriteDump(t *testing.T) {
	platform := sealedRow(t, sourceKey, "a1", "postgresql", "postgresql://postgres:old@postgres:5432/commerce")
	external := sealedRow(t, sourceKey, "a2", "postgresql", "postgresql://postgres:old@db.example.com:5432/x")
	foreign := sealedRow(t, otherKey, "a3", "postgresql", "postgresql://postgres:old@postgres:5432/x")
	nulls := "a4\tagency\tsqlite\tn\t\\N\t\\N\t\\N\t\\N\t2026-01-01\n"
	other := "COPY public.tenants (id) FROM stdin;\nagency\n\\.\n"
	in := "SET x = 1;\n" + other + header + platform + external + foreign + nulls + "\\.\n" + other + "-- end"
	var out strings.Builder
	stats, err := RewriteDump(bufio.NewReader(strings.NewReader(in)), &out, Config{SourceKey: sourceKey, TargetKey: targetKey, Targets: testTargets()})
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.SplitAfter(out.String(), "\n")
	if got := openRow(t, targetKey, lines[5]); got != "postgresql://postgres:n3w%2Fp%40ss%3Aword@postgres:5432/commerce" {
		t.Fatalf("rebound row opens to %q", got)
	}
	if got := openRow(t, targetKey, lines[6]); got != "postgresql://postgres:old@db.example.com:5432/x" {
		t.Fatalf("kept row must open under the target key to its own DSN, got %q", got)
	}
	want := strings.Replace(strings.Replace(in, platform, lines[5], 1), external, lines[6], 1)
	if out.String() != want {
		t.Fatalf("bytes outside the re-sealed rows changed:\n%q\nwant\n%q", out.String(), want)
	}
	assertStats(t, stats, []Outcome{Rebound, Unmatched, Undecryptable, NoCiphertext}, []bool{true, true, false, false})
}

func assertStats(t *testing.T, stats Stats, want []Outcome, resealed []bool) {
	t.Helper()
	if stats.Blocks != 1 || len(stats.Rows) != len(want) {
		t.Fatalf("stats = %+v; want 1 block and %d rows", stats, len(want))
	}
	for i, o := range want {
		if r := stats.Rows[i]; r.Outcome != o || r.Resealed != resealed[i] {
			t.Fatalf("row %d (%s) = %q resealed=%v; want %q resealed=%v", i, r.ID, r.Outcome, r.Resealed, o, resealed[i])
		}
	}
}

func TestRewriteDumpRefusesShortKeys(t *testing.T) {
	_, err := RewriteDump(bufio.NewReader(strings.NewReader("")), &strings.Builder{}, Config{SourceKey: "short", TargetKey: targetKey})
	if err == nil {
		t.Fatal("a source key under 16 characters must be refused")
	}
}

// A row no key opens, named in Reseat, gets a new DSN from the target's login; one that is
// not named stays exactly as it was, because the tool must never guess a target.
func TestRewriteDumpReseatsANamedRow(t *testing.T) {
	lost := sealedRow(t, otherKey, "b1", "postgresql", "postgresql://postgres:old@postgres:5432/website")
	unnamed := strings.Replace(sealedRow(t, otherKey, "b2", "postgresql", "postgresql://u:p@postgres/y"), "\tn\t", "\tother\t", 1)
	in := header + lost + unnamed + "\\.\n"
	var out strings.Builder
	cfg := Config{SourceKey: sourceKey, TargetKey: targetKey, Targets: pgTargets(), Reseat: map[string]string{"n": "website"}}
	stats, err := RewriteDump(bufio.NewReader(strings.NewReader(in)), &out, cfg)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.SplitAfter(out.String(), "\n")
	if got := openRow(t, targetKey, lines[1]); got != "postgres://postgres:n3w%2Fp%40ss%3Aword@postgres:5432/website" {
		t.Fatalf("reseated row opens to %q", got)
	}
	if lines[2] != unnamed {
		t.Fatalf("a row not named in Reseat changed: %q", lines[2])
	}
	assertStats(t, stats, []Outcome{Reseated, Undecryptable}, []bool{true, false})
}

// A row the source key still opens is rebound, never reseated, even when it is named.
func TestReseatLeavesAnOpenRowAlone(t *testing.T) {
	open := sealedRow(t, sourceKey, "c1", "postgresql", "postgresql://postgres:old@postgres:5432/commerce")
	in := header + open + "\\.\n"
	var out strings.Builder
	cfg := Config{SourceKey: sourceKey, TargetKey: targetKey, Targets: pgTargets(), Reseat: map[string]string{"n": "wrong"}}
	stats, err := RewriteDump(bufio.NewReader(strings.NewReader(in)), &out, cfg)
	if err != nil {
		t.Fatal(err)
	}
	assertStats(t, stats, []Outcome{Rebound}, []bool{true})
}

// With no login for the engine there is nothing to build a DSN from, so the row stays.
func TestReseatWithoutATargetKeepsTheRow(t *testing.T) {
	lost := sealedRow(t, otherKey, "d1", "postgresql", "postgresql://u:p@postgres/z")
	in := header + lost + "\\.\n"
	var out strings.Builder
	cfg := Config{SourceKey: sourceKey, TargetKey: targetKey, Reseat: map[string]string{"n": "z"}}
	stats, err := RewriteDump(bufio.NewReader(strings.NewReader(in)), &out, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if out.String() != in {
		t.Fatalf("the row changed: %q", out.String())
	}
	assertStats(t, stats, []Outcome{Undecryptable}, []bool{false})
}

func pgTargets() []Target {
	return []Target{{Engine: "postgresql", Schemes: []string{"postgres", "postgresql"}, Hosts: []string{"postgres", "mini-baas-postgres"}, Port: 5432, User: "postgres", Password: "n3w/p@ss:word"}}
}
