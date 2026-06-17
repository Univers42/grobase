package export

import (
	"context"
	"encoding/json"
	"fmt"
	"io"

	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// extractTo streams the portable bundle into the store under key and returns the
// computed manifest plus the store-resolved location/size/sha. It uses an
// io.Pipe so the JSON stream flows straight into Upload without buffering the
// whole bundle; the manifest is captured out of the writer goroutine via a
// buffered channel (writeBundle returns it).
func (s *Service) extractTo(ctx context.Context, iso, tenantID, key string) (Manifest, string, int64, string, error) {
	schema := ""
	if iso == "schema_per_tenant" {
		schema = tenants.TenantSchema(tenantID)
	}
	pr, pw := io.Pipe()
	manCh := make(chan Manifest, 1)
	go func() {
		m, werr := extractScoped(ctx, scopedExtract{db: s.db, iso: iso, tenantID: tenantID, schema: schema, w: pw})
		manCh <- m
		_ = pw.CloseWithError(werr)
	}()
	location, size, sha, err := s.store.Upload(ctx, key, pr)
	manifest := <-manCh
	if err != nil {
		return Manifest{}, "", 0, "", err
	}
	return manifest, location, size, sha, nil
}

// markFailed records a best-effort 'failed' status + error on the ledger row;
// the error is intentionally swallowed (the original extract error is returned).
func (s *Service) markFailed(ctx context.Context, exportID string, cause error) {
	_ = s.db.AdminExec(ctx,
		`UPDATE public.tenant_exports SET status='failed', error_message=$2 WHERE id=$1`,
		exportID, cause.Error())
}

// completion groups the finalized-bundle facts markCompleted writes to the
// ledger row: export id, manifest, store location, byte size, and sha256.
type completion struct {
	exportID string
	manifest Manifest
	location string
	size     int64
	sha      string
}

// markCompleted finalizes the ledger row with the bundle's manifest, location,
// size, sha256, and counts.
func (s *Service) markCompleted(ctx context.Context, c completion) error {
	mb, _ := json.Marshal(c.manifest)
	if uerr := s.db.AdminExec(ctx,
		`UPDATE public.tenant_exports
		    SET status='completed', location=$2, size_bytes=$3, sha256=$4,
		        table_count=$5, row_count=$6, manifest=$7::jsonb, completed_at=now()
		  WHERE id=$1`,
		c.exportID, c.location, c.size, c.sha, c.manifest.TableCount, c.manifest.RowCount, string(mb)); uerr != nil {
		return fmt.Errorf("export: finalize ledger row: %w", uerr)
	}
	return nil
}
