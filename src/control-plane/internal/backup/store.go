// Package backup implements per-tenant logical backup + restore (Track-B B6).
//
// The data path is Go-native logical export over the EXISTING pgx pool: COPY ...
// TO STDOUT streams each table into an [ArtifactStore]; restore replays COPY ...
// FROM STDIN inside one transaction per scope (atomic — full restore or full
// rollback, never partial). No pg_dump binary, no image change.
//
// MVP supports the two clean isolation models only — schema_per_tenant and
// db_per_tenant. shared_rls (filtered dump + upsert into a LIVE shared table)
// and tenant_owned (external DB) are DEFERRED and rejected with a 400-mapped
// [ErrIsolationDeferred].
//
// The whole surface is flag-gated by TENANT_BACKUP_ENABLED (default OFF); when
// off, main.go never mounts the routes, so nothing in this package ever runs and
// the table stays empty = byte-parity baseline.
package backup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// ArtifactStore is the storage abstraction behind which a backup artifact is
// persisted. The DEFAULT backend is [LocalFileStore] (the gate needs no MinIO
// container on the RAM-constrained box); [MinIOStore] is the production backend
// behind the SAME interface so the code path is identical.
//
// Upload streams r to the artifact identified by key and returns the resolved
// location (a path or an s3:// URL), the byte size written, and the lower-hex
// sha256 of the bytes (computed in-stream, never buffering the whole artifact).
type ArtifactStore interface {
	Upload(ctx context.Context, key string, r io.Reader) (location string, size int64, sha256hex string, err error)
	Download(ctx context.Context, key string, w io.Writer) error
	Delete(ctx context.Context, key string) error
}

// ── LocalFileStore (default / gate) ──────────────────────────────────────────

// LocalFileStore writes artifacts under dir/<key>. It computes sha256 in-stream
// via io.TeeReader and publishes atomically (temp file -> rename) so a partial
// write is never observable as a completed artifact.
type LocalFileStore struct{ dir string }

// NewLocalFileStore returns a filesystem-backed ArtifactStore rooted at dir.
func NewLocalFileStore(dir string) *LocalFileStore { return &LocalFileStore{dir: dir} }

func (s *LocalFileStore) path(key string) string {
	// key is "<tenant>/<backupId>"; both are sanitized upstream (tenant id and a
	// gen_random_uuid()), but Clean defends against any "../" regardless.
	return filepath.Join(s.dir, filepath.Clean("/"+key))
}

func (s *LocalFileStore) Upload(ctx context.Context, key string, r io.Reader) (string, int64, string, error) {
	dst := s.path(key)
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		return "", 0, "", fmt.Errorf("backup: mkdir artifact dir: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".bak-*")
	if err != nil {
		return "", 0, "", fmt.Errorf("backup: create temp artifact: %w", err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // no-op after a successful rename

	n, sum, err := streamToTemp(tmp, r)
	if err != nil {
		return "", 0, "", err
	}
	if err := os.Rename(tmpName, dst); err != nil {
		return "", 0, "", fmt.Errorf("backup: publish artifact: %w", err)
	}
	return dst, n, sum, nil
}

// streamToTemp copies r into tmp while computing sha256 in-stream, then fsyncs
// and closes tmp. It returns the byte count and lower-hex sha. tmp is always
// closed (on success or any error) so the caller's deferred Remove can fire.
func streamToTemp(tmp *os.File, r io.Reader) (int64, string, error) {
	h := sha256.New()
	n, err := io.Copy(tmp, io.TeeReader(r, h))
	if err != nil {
		_ = tmp.Close()
		return 0, "", fmt.Errorf("backup: write artifact: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return 0, "", fmt.Errorf("backup: sync artifact: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return 0, "", fmt.Errorf("backup: close artifact: %w", err)
	}
	return n, hex.EncodeToString(h.Sum(nil)), nil
}
