package backup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
)

// ErrArtifactUnverified refuses a restore whose ledger row carries no sha256
// (a pending or failed backup): there is nothing to check the artifact against.
const ErrArtifactUnverified backupErr = "backup: the ledger holds no sha256 for this backup — restore refused"

// ErrArtifactIntegrity refuses an artifact whose stored bytes differ from the
// ledger's sha256 — tampered, truncated, or another backup swapped in.
const ErrArtifactIntegrity backupErr = "backup: artifact does not match the ledger sha256 — restore refused"

// errRestoreRead unblocks the download goroutine once the restore stops reading.
const errRestoreRead backupErr = "backup: artifact read ended"

// restorer returns the replay for the tenant's isolation model, checking the
// scope (schema, DSN) before anything is downloaded.
func (s *Service) restorer(iso, tenantID, dsn string) (func(context.Context, []byte) error, error) {
	switch iso {
	case "schema_per_tenant":
		schema := s.schemaFor(tenantID)
		if schema == "" {
			return nil, fmt.Errorf("backup: tenant id %q sanitizes to empty schema", tenantID)
		}
		return func(ctx context.Context, b []byte) error { return restoreSchema(ctx, s.db, schema, b) }, nil
	case "db_per_tenant":
		if dsn == "" {
			return nil, fmt.Errorf("backup: db_per_tenant restore requires a resolved DSN (no resolver wired)")
		}
		return func(ctx context.Context, b []byte) error { return restoreDatabase(ctx, dsn, b) }, nil
	default:
		return nil, ErrIsolationDeferred
	}
}

// fetchVerified downloads the artifact of row at key, hashes every stored byte
// while the sealer opens it, and returns the plaintext only when that hash equals
// the ledger's sha256. It reads at most size_bytes+1 bytes, so an oversized
// artifact is refused, never buffered. The download goroutine is always
// unblocked and awaited.
func (s *Service) fetchVerified(ctx context.Context, key string, row restoreRow) ([]byte, error) {
	if row.sha == "" {
		return nil, ErrArtifactUnverified
	}
	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() {
		_ = pw.CloseWithError(s.store.Download(ctx, key, pw))
		close(done)
	}()
	h := sha256.New()
	stored := &io.LimitedReader{R: pr, N: row.size + 1}
	plain, err := s.seal.open(io.TeeReader(stored, h), row.sealed())
	_ = pr.CloseWithError(errRestoreRead)
	<-done
	if stored.N == 0 {
		return nil, ErrArtifactIntegrity
	}
	if err != nil {
		return nil, err
	}
	if hex.EncodeToString(h.Sum(nil)) != row.sha {
		return nil, ErrArtifactIntegrity
	}
	return plain, nil
}
