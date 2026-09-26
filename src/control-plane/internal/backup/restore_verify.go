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

// fetchVerified downloads the artifact at key, hashes every stored byte while
// the sealer opens it, and returns the plaintext only when that hash equals the
// ledger's wantSHA. The download goroutine is always unblocked and awaited.
func (s *Service) fetchVerified(ctx context.Context, key, wantSHA string) ([]byte, error) {
	if wantSHA == "" {
		return nil, ErrArtifactUnverified
	}
	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() {
		_ = pw.CloseWithError(s.store.Download(ctx, key, pw))
		close(done)
	}()
	h := sha256.New()
	plain, err := s.seal.open(io.TeeReader(pr, h))
	_ = pr.CloseWithError(errRestoreRead)
	<-done
	if err != nil {
		return nil, err
	}
	if hex.EncodeToString(h.Sum(nil)) != wantSHA {
		return nil, ErrArtifactIntegrity
	}
	return plain, nil
}
