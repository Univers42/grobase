package backup

import (
	"path/filepath"
	"testing"
)

// TestNewStoreFromEnvLocalDefault asserts that with no MinIO env set, the
// selector returns a LocalFileStore rooted at BACKUP_DATA_DIR (here a TempDir,
// which it must create). It pins both the concrete type and the resolved dir.
func TestNewStoreFromEnvLocalDefault(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "artifacts")
	t.Setenv("MINIO_ENDPOINT", "")
	t.Setenv("MINIO_ROOT_USER", "")
	t.Setenv("BACKUP_DATA_DIR", dir)

	store, err := NewStoreFromEnv()
	if err != nil {
		t.Fatalf("NewStoreFromEnv: %v", err)
	}
	local, ok := store.(*LocalFileStore)
	if !ok {
		t.Fatalf("store type = %T, want *LocalFileStore", store)
	}
	if local.dir != dir {
		t.Fatalf("local dir = %q, want %q", local.dir, dir)
	}
}

// TestNewStoreFromEnvMinIORequiresBothVars asserts the MinIO branch is taken
// ONLY when BOTH MINIO_ENDPOINT and MINIO_ROOT_USER are set. Setting just one
// must fall through to the LocalFileStore default — a half-configured MinIO must
// never silently select the production backend.
func TestNewStoreFromEnvMinIORequiresBothVars(t *testing.T) {
	cases := []struct {
		name, endpoint, user string
	}{
		{"endpoint only", "minio:9000", ""},
		{"user only", "", "root"},
		{"neither", "", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "art")
			t.Setenv("MINIO_ENDPOINT", tc.endpoint)
			t.Setenv("MINIO_ROOT_USER", tc.user)
			t.Setenv("BACKUP_DATA_DIR", dir)

			store, err := NewStoreFromEnv()
			if err != nil {
				t.Fatalf("NewStoreFromEnv: %v", err)
			}
			if _, ok := store.(*LocalFileStore); !ok {
				t.Fatalf("with %s, store type = %T, want *LocalFileStore", tc.name, store)
			}
		})
	}
}
