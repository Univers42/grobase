package export

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// ErrIsolationDeferred is returned when an export is requested for an isolation
// model D4.3 does NOT support: db_per_tenant (needs the DSN resolver, B6b-style)
// and tenant_owned (external DB). The handler maps it to 400. The deferral is
// also enforced structurally by the 052 CHECK (a row for a deferred model cannot
// be inserted).
var ErrIsolationDeferred = errors.New("isolation not supported for export (deferred)")

// ErrNoMount is returned when the tenant has no registered mount to export.
var ErrNoMount = errors.New("tenant has no registered data mount")

// ErrNotFound mirrors tenants.ErrNotFound at this package boundary (the self-serve
// read route maps it to 404).
var ErrNotFound = errors.New("tenant not found")

// Service orchestrates per-tenant data EXPORT over the shared control-plane
// Postgres (the tenant_exports ledger + schema_per_tenant / shared_rls data) and
// an ArtifactStore (where the portable bundle lands). It reuses the SAME data
// scoping the B6 backup + D4.4 erase services use (tenants.TenantSchema for
// schema_per_tenant, the shared-table discovery + tenant_id filter for
// shared_rls) so an export sees exactly one tenant's data.
type Service struct {
	db    *shared.Postgres
	store ArtifactStore
	keys  *tenants.Service // optional: credential resolution for the self-serve read route
	log   *slog.Logger
}

// NewService builds the export service.
func NewService(db *shared.Postgres, store ArtifactStore, log *slog.Logger) *Service {
	return &Service{db: db, store: store, log: log}
}

// WithTenants wires the tenants.Service used ONLY by the optional, default-OFF
// self-serve read route (/v1/tenants/me/exports) to resolve a credential to its
// owning tenant. The admin routes never consult it. Delegating to tenants.Service
// keeps the (sensitive) key-hashing scheme single-sourced — no re-implementation,
// no drift. Mirrors backup.Service.WithTenants.
func (s *Service) WithTenants(t *tenants.Service) *Service { s.keys = t; return s }

// VerifyKey resolves a raw tenant API key to its tenant slug via the
// single-source tenants verifier. Used only by the self-serve read route.
func (s *Service) VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error) {
	if s.keys == nil {
		return tenants.VerifyKeyResponse{}, fmt.Errorf("export: self-serve key verification not wired")
	}
	return s.keys.VerifyKey(ctx, raw)
}

// ExportRow is one ledger row (the ListExports element + the export response).
type ExportRow struct {
	ID         string          `json:"id"`
	TenantID   string          `json:"tenant_id"`
	Mount      string          `json:"mount,omitempty"`
	Isolation  string          `json:"isolation"`
	Engine     string          `json:"engine"`
	Format     string          `json:"format"`
	Status     string          `json:"status"`
	Location   string          `json:"location,omitempty"`
	TableCount int             `json:"table_count"`
	RowCount   int64           `json:"row_count"`
	SizeBytes  int64           `json:"size_bytes"`
	SHA256     string          `json:"sha256,omitempty"`
	Manifest   json.RawMessage `json:"manifest,omitempty"`
	CreatedAt  string          `json:"created_at"`
}

// isolationFor resolves the isolation model for the tenant from
// public.tenant_databases (tenant_id ALWAYS a bind param — the cross-tenant
// wall). When the tenant has multiple mounts they must share one isolation model
// for a whole-tenant export; the first row's isolation is authoritative (mirrors
// erase.scopeFor). An empty mount means whole-tenant; a named mount narrows the
// lookup. Returns ErrNoMount when there is no row.
func (s *Service) isolationFor(ctx context.Context, tenantID, mount string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation FROM public.tenant_databases
		  WHERE tenant_id = $1 AND ($2 = '' OR name = $2)
		  ORDER BY created_at LIMIT 1`, tenantID, mount)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", rerr
		}
		return "", ErrNoMount
	}
	var iso string
	if err := rows.Scan(&iso); err != nil {
		return "", err
	}
	return iso, nil
}

// guardIsolation rejects the isolation models D4.3 does not support. Only
// schema_per_tenant and shared_rls are exportable in the MVP.
func guardIsolation(iso string) error {
	switch iso {
	case "schema_per_tenant", "shared_rls":
		return nil
	default:
		return ErrIsolationDeferred
	}
}

// insertPending records a new export row in 'pending' state and returns its id.
// tenant_id, mount, isolation are bind params; an empty mount stores NULL.
func (s *Service) insertPending(ctx context.Context, tenantID, mount, iso string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`INSERT INTO public.tenant_exports (tenant_id, mount, isolation, engine, format, location, status)
		 VALUES ($1, NULLIF($2,''), $3, 'postgresql', 'json', '', 'pending')
		 RETURNING id::text`, tenantID, mount, iso)
	if err != nil {
		return "", fmt.Errorf("export: insert ledger row: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", fmt.Errorf("export: insert ledger row: %w", rerr)
		}
		return "", fmt.Errorf("export: insert ledger row returned no id")
	}
	var id string
	if err := rows.Scan(&id); err != nil {
		return "", fmt.Errorf("export: scan inserted id: %w", err)
	}
	return id, nil
}

// CreateExport produces a PORTABLE bundle of ONE tenant's data and records it.
// Flow: resolve+guard isolation -> INSERT status='pending' -> stream bundle into
// the store (which tees size+sha256) -> UPDATE status='completed' (manifest /
// counts / sha) or 'failed'. Returns the export id. tenant_id is always a bind
// param, and the SELECTs are scoped to the tenant's own schema / WHERE tenant_id,
// so the bundle can NEVER contain another tenant's rows.
func (s *Service) CreateExport(ctx context.Context, tenantID, mount string) (string, error) {
	iso, err := s.isolationFor(ctx, tenantID, mount)
	if err != nil {
		return "", err
	}
	if err := guardIsolation(iso); err != nil {
		return "", err
	}

	exportID, err := s.insertPending(ctx, tenantID, mount, iso)
	if err != nil {
		return "", err
	}

	key := tenantID + "/" + exportID
	manifest, location, size, sha, xerr := s.extractTo(ctx, iso, tenantID, key)
	if xerr != nil {
		_ = s.db.AdminExec(ctx,
			`UPDATE public.tenant_exports SET status='failed', error_message=$2 WHERE id=$1`,
			exportID, xerr.Error())
		return exportID, xerr
	}

	mb, _ := json.Marshal(manifest)
	if uerr := s.db.AdminExec(ctx,
		`UPDATE public.tenant_exports
		    SET status='completed', location=$2, size_bytes=$3, sha256=$4,
		        table_count=$5, row_count=$6, manifest=$7::jsonb, completed_at=now()
		  WHERE id=$1`,
		exportID, location, size, sha, manifest.TableCount, manifest.RowCount, string(mb)); uerr != nil {
		return exportID, fmt.Errorf("export: finalize ledger row: %w", uerr)
	}
	return exportID, nil
}

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
		m, werr := extractScoped(ctx, s.db, iso, tenantID, schema, pw)
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

// ListExports returns the tenant's exports, most-recent-first. tenant_id is a
// bind param; RLS is a second wall for the self-serve read path.
func (s *Service) ListExports(ctx context.Context, tenantID string) ([]ExportRow, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT id::text, tenant_id, COALESCE(mount,''), isolation, engine, format, status,
		        location, table_count, row_count, size_bytes, COALESCE(sha256,''),
		        manifest, created_at::text
		   FROM public.tenant_exports
		  WHERE tenant_id = $1
		  ORDER BY created_at DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ExportRow
	for rows.Next() {
		var e ExportRow
		var man []byte
		if err := rows.Scan(&e.ID, &e.TenantID, &e.Mount, &e.Isolation, &e.Engine, &e.Format,
			&e.Status, &e.Location, &e.TableCount, &e.RowCount, &e.SizeBytes, &e.SHA256,
			&man, &e.CreatedAt); err != nil {
			return nil, err
		}
		if len(man) > 0 {
			e.Manifest = json.RawMessage(man)
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Download streams a completed export bundle to w, AFTER verifying the export id
// belongs to the requesting tenant (the load-bearing caller==owner check: the
// lookup binds id AND tenant_id, so an id that is not the caller's — or does not
// exist — yields ErrNotFound, never another tenant's bundle). Used by the
// admin + self download routes so a tenant gets the actual portable file, not
// just the ledger row.
func (s *Service) Download(ctx context.Context, tenantID, exportID string, w io.Writer) error {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT status FROM public.tenant_exports
		  WHERE id = $1 AND tenant_id = $2`, exportID, tenantID)
	if err != nil {
		return fmt.Errorf("export: load row: %w", err)
	}
	found := rows.Next()
	var status string
	if found {
		if serr := rows.Scan(&status); serr != nil {
			rows.Close()
			return serr
		}
	}
	rows.Close()
	if rerr := rows.Err(); rerr != nil {
		return rerr
	}
	if !found {
		// Load-bearing caller==owner: an id that is not the caller's (or unknown) is
		// indistinguishable -> ErrNotFound (404). No bytes are streamed.
		return ErrNotFound
	}
	if status != "completed" {
		return fmt.Errorf("export %s is not completed (status=%s)", exportID, status)
	}
	key := tenantID + "/" + exportID
	return s.store.Download(ctx, key, w)
}

// TenantForUser resolves a GoTrue user id to the slug of the tenant it owns.
// Used only by the self-serve read route. Mirrors backup.Service.TenantForUser.
func (s *Service) TenantForUser(ctx context.Context, userID string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT slug FROM public.tenants WHERE owner_user_id = $1 LIMIT 1`, userID)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", rerr
		}
		return "", ErrNotFound
	}
	var slug string
	if err := rows.Scan(&slug); err != nil {
		return "", err
	}
	return slug, nil
}
