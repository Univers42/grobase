package backup

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
)

// fakeStore is an in-memory ArtifactStore for exercising the Service's
// store-facing seams (extractTo/replayInto) without a filesystem or MinIO.
type fakeStore struct {
	uploaded map[string][]byte
	content  []byte
	dlErr    error
}

func newFakeStore() *fakeStore { return &fakeStore{uploaded: map[string][]byte{}} }

// Upload drains r (so a pipe writer's CloseWithError surfaces here) and records
// the bytes under key, returning a deterministic location/size/sha-less result.
func (f *fakeStore) Upload(_ context.Context, key string, r io.Reader) (string, int64, string, error) {
	b, err := io.ReadAll(r)
	if err != nil {
		return "", 0, "", err
	}
	f.uploaded[key] = b
	return "fake://" + key, int64(len(b)), "sha", nil
}

func (f *fakeStore) Download(_ context.Context, _ string, w io.Writer) error {
	if f.dlErr != nil {
		return f.dlErr
	}
	_, err := w.Write(f.content)
	return err
}

func (f *fakeStore) Delete(_ context.Context, _ string) error { return nil }

// svcWithStore builds a Service with a fake store and NO db/resolver — valid for
// the isolation arms that never reach the DB (deferred + missing-DSN paths).
func svcWithStore(store ArtifactStore) *Service {
	return &Service{store: store}
}

// TestExtractToDeferredIsolation asserts extractTo's default arm propagates
// ErrIsolationDeferred through the io.Pipe into Upload — an unknown isolation
// model must fail the extract, never produce a silent empty artifact.
func TestExtractToDeferredIsolation(t *testing.T) {
	s := svcWithStore(newFakeStore())
	_, _, _, err := s.extractTo(context.Background(), "shared_rls", "tenant-1", "", "tenant-1/b1")
	if !errors.Is(err, ErrIsolationDeferred) {
		t.Fatalf("extractTo(shared_rls) = %v, want ErrIsolationDeferred", err)
	}
}

// TestExtractToDBPerTenantNoDSN asserts that db_per_tenant without a resolved DSN
// fails cleanly (the documented "no resolver wired" guard) instead of panicking.
func TestExtractToDBPerTenantNoDSN(t *testing.T) {
	s := svcWithStore(newFakeStore())
	_, _, _, err := s.extractTo(context.Background(), "db_per_tenant", "tenant-1", "", "tenant-1/b1")
	if err == nil {
		t.Fatalf("extractTo(db_per_tenant, no dsn) = nil error")
	}
	if !strings.Contains(err.Error(), "requires a resolved DSN") {
		t.Fatalf("error = %v, want requires a resolved DSN", err)
	}
}

// TestReplayIntoDeferredIsolation asserts replayInto's default arm returns
// ErrIsolationDeferred without attempting any DDL.
func TestReplayIntoDeferredIsolation(t *testing.T) {
	s := svcWithStore(newFakeStore())
	err := s.replayInto(context.Background(), "tenant_owned", "tenant-1", "", "tenant-1/b1")
	if !errors.Is(err, ErrIsolationDeferred) {
		t.Fatalf("replayInto(tenant_owned) = %v, want ErrIsolationDeferred", err)
	}
}

// TestReplayIntoDBPerTenantNoDSN asserts db_per_tenant restore without a DSN
// errors with the documented guard rather than proceeding.
func TestReplayIntoDBPerTenantNoDSN(t *testing.T) {
	s := svcWithStore(newFakeStore())
	err := s.replayInto(context.Background(), "db_per_tenant", "tenant-1", "", "tenant-1/b1")
	if err == nil {
		t.Fatalf("replayInto(db_per_tenant, no dsn) = nil error")
	}
	if !strings.Contains(err.Error(), "requires a resolved DSN") {
		t.Fatalf("error = %v, want requires a resolved DSN", err)
	}
}

// TestVerifyKeyUnwired asserts VerifyKey fails closed when the tenants.Service is
// not wired (the self-serve route is optional/default-OFF): no panic, a clear
// "not wired" error, and an invalid (zero-value) response.
func TestVerifyKeyUnwired(t *testing.T) {
	s := &Service{}
	resp, err := s.VerifyKey(context.Background(), "raw-key")
	if err == nil {
		t.Fatalf("VerifyKey(unwired) = nil error")
	}
	if !strings.Contains(err.Error(), "not wired") {
		t.Fatalf("error = %v, want not wired", err)
	}
	if resp.Valid {
		t.Fatalf("unwired VerifyKey returned Valid=true")
	}
}

// TestSchemaForDelegates asserts schemaFor is a deterministic single-source
// wrapper: identical tenant ids map to identical schemas and distinct ids map to
// distinct schemas (the wrapper must not collapse tenants — that would be a
// cross-tenant bug).
func TestSchemaForDelegates(t *testing.T) {
	s := &Service{}
	a1 := s.schemaFor("tenant-alpha")
	a2 := s.schemaFor("tenant-alpha")
	b := s.schemaFor("tenant-beta")
	if a1 == "" {
		t.Fatalf("schemaFor(non-empty id) returned empty schema")
	}
	if a1 != a2 {
		t.Fatalf("schemaFor not deterministic: %q vs %q", a1, a2)
	}
	if a1 == b {
		t.Fatalf("schemaFor collapsed distinct tenants to %q", a1)
	}
}

// TestExtractToSchemaUploadsViaStore is a sanity check that the schema arm reaches
// the store seam: the empty-schema guard fires for a tenant id that sanitizes to
// an empty schema, surfacing through the pipe rather than uploading silently.
func TestExtractToSchemaEmptyGuard(t *testing.T) {
	s := svcWithStore(newFakeStore())
	if s.schemaFor("") != "" {
		t.Skip("tenant id sanitizer does not map empty to empty; guard not reachable here")
	}
	_, _, _, err := s.extractTo(context.Background(), "schema_per_tenant", "", "", "/b1")
	if err == nil {
		t.Fatalf("extractTo(schema_per_tenant, empty schema) = nil error")
	}
	if !strings.Contains(err.Error(), "empty schema") {
		t.Fatalf("error = %v, want empty schema", err)
	}
}

// drainPipeBody is a guard against the io.Pipe goroutine leaking on a store that
// never reads; the fakeStore always drains, asserted indirectly here.
func TestFakeStoreDrains(t *testing.T) {
	f := newFakeStore()
	_, n, _, err := f.Upload(context.Background(), "k", bytes.NewReader([]byte("xyz")))
	if err != nil || n != 3 {
		t.Fatalf("fakeStore.Upload = (%d,%v), want (3,nil)", n, err)
	}
	if string(f.uploaded["k"]) != "xyz" {
		t.Fatalf("fakeStore did not record bytes: %q", f.uploaded["k"])
	}
}
