package backup

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/tenants"
)

// ErrNotOwned is returned when a restore (or list-by-id) references a backup
// whose tenant_id does not match the requesting tenant. The handler maps it to
// 403/404 — the load-bearing caller==owner check, enforced BEFORE any DDL.
var ErrNotOwned = errors.New("backup not found for tenant")

// ErrNotFound is returned by TenantForUser when a GoTrue user owns no tenant
// yet (the read-only self-serve route maps it to 404 with a bootstrap hint).
// Mirrors tenants.ErrNotFound at the backup-package boundary so the self-serve
// handler depends only on this package's sentinel.
var ErrNotFound = errors.New("tenant not found")

// ConnResolver is the seam by which the service resolves a db_per_tenant
// tenant's OWN database DSN. It mirrors the adapterregistry GetConnection
// contract (caller==owner is enforced by the resolver: WHERE id=$1 AND
// tenant_id=$2). main.go (the endpoint slice) wires a concrete resolver; for
// schema_per_tenant the resolver is never consulted (the schema lives in the
// control-plane DB and the name comes from tenants.TenantSchema).
type ConnResolver interface {
	// Resolve returns the isolation model and (for db_per_tenant) the decrypted
	// DSN for the tenant's mount. dsn is "" for schema_per_tenant.
	Resolve(ctx context.Context, tenantID, mount string) (isolation, dsn string, err error)
}

// Service orchestrates per-tenant backup + restore over the shared control-plane
// Postgres (for the tenant_backups ledger + schema_per_tenant data), an
// ArtifactStore (where artifacts land), and a ConnResolver (db_per_tenant DSN).
type Service struct {
	db    *pg.Postgres
	store ArtifactStore
	res   ConnResolver
	keys  *tenants.Service // optional: credential resolution for the self-serve read route
	log   *slog.Logger
}

// NewService builds the backup service. The ConnResolver is optional at
// construction (schema_per_tenant works without it); a nil resolver makes
// db_per_tenant backups fail cleanly with a clear error rather than panicking.
func NewService(db *pg.Postgres, store ArtifactStore, log *slog.Logger) *Service {
	return &Service{db: db, store: store, log: log}
}

// WithResolver wires the db_per_tenant DSN resolver (called from main.go after
// the adapter-registry client is available).
func (s *Service) WithResolver(r ConnResolver) *Service { s.res = r; return s }

// WithTenants wires the tenants.Service used ONLY by the optional, default-OFF
// self-serve read route (/v1/tenants/me/backups) to resolve a credential to its
// owning tenant. The admin routes never consult it. Delegating to tenants.Service
// for key verification keeps the (sensitive) hashing scheme single-sourced —
// no re-implementation, no drift.
func (s *Service) WithTenants(t *tenants.Service) *Service { s.keys = t; return s }

// schemaFor mirrors tenants.tenantSchema via the EXPORTED single-source wrapper
// (NEVER re-implemented here — drift would be a cross-tenant bug; see
// internal/tenants/schema_export.go).
func (s *Service) schemaFor(tenantID string) string { return tenants.TenantSchema(tenantID) }

// BackupRow is one ledger row (the ListBackups element + Restore lookup shape).
type BackupRow struct {
	ID        string `json:"id"`
	TenantID  string `json:"tenant_id"`
	Mount     string `json:"mount,omitempty"`
	Isolation string `json:"isolation"`
	Engine    string `json:"engine"`
	Status    string `json:"status"`
	Location  string `json:"location,omitempty"`
	SizeBytes int64  `json:"size_bytes"`
	SHA256    string `json:"sha256,omitempty"`
	CreatedAt string `json:"created_at"`
}

// isolationFor resolves the isolation model for (tenant, mount). When a resolver
// is wired it is authoritative (it also yields the db_per_tenant DSN); otherwise
// the control-plane DB is consulted directly (schema_per_tenant path).
func (s *Service) isolationFor(ctx context.Context, tenantID, mount string) (iso, dsn string, err error) {
	if s.res != nil {
		return s.res.Resolve(ctx, tenantID, mount)
	}
	// Fallback: read isolation straight from tenant_databases (tenant_id always a
	// bind param). No DSN decryption here — db_per_tenant needs a resolver.
	rows, qerr := s.db.AdminQuery(ctx,
		`SELECT isolation FROM public.tenant_databases
		  WHERE tenant_id = $1 AND ($2 = '' OR name = $2)
		  ORDER BY created_at LIMIT 1`, tenantID, mount)
	if qerr != nil {
		return "", "", qerr
	}
	defer rows.Close()
	if !rows.Next() {
		return "", "", fmt.Errorf("backup: no mount for tenant %q", tenantID)
	}
	if err := rows.Scan(&iso); err != nil {
		return "", "", err
	}
	return iso, "", nil
}
