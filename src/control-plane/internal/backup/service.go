package backup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
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
	db    *shared.Postgres
	store ArtifactStore
	res   ConnResolver
	keys  *tenants.Service // optional: credential resolution for the self-serve read route
	log   *slog.Logger
}

// NewService builds the backup service. The ConnResolver is optional at
// construction (schema_per_tenant works without it); a nil resolver makes
// db_per_tenant backups fail cleanly with a clear error rather than panicking.
func NewService(db *shared.Postgres, store ArtifactStore, log *slog.Logger) *Service {
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

// VerifyKey resolves a raw tenant API key to its tenant slug, delegating to the
// single-source tenants.Service verifier (the returned VerifyKeyResponse exposes
// .Valid and .TenantID, which is the tenant slug). Used only by the self-serve
// read route. Mirrors the MODULE-SLICE CONTRACT in handler.go.
func (s *Service) VerifyKey(ctx context.Context, raw string) (tenants.VerifyKeyResponse, error) {
	if s.keys == nil {
		return tenants.VerifyKeyResponse{}, fmt.Errorf("backup: self-serve key verification not wired")
	}
	return s.keys.VerifyKey(ctx, raw)
}

// TenantForUser resolves a GoTrue user id to the slug of the tenant it owns,
// returning ErrNotFound when the user owns no tenant yet. tenant_id is keyed by
// owner_user_id (mirrors tenants.findForUser; userID is a bind param). Used only
// by the self-serve read route.
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

// insertPending records a new backup row in 'pending' state and returns its id.
// tenant_id and mount are bind params; an empty mount stores NULL.
func (s *Service) insertPending(ctx context.Context, tenantID, mount, iso string) (string, error) {
	rows, err := s.db.AdminQuery(ctx,
		`INSERT INTO public.tenant_backups (tenant_id, mount, isolation, engine, location, status)
		 VALUES ($1, NULLIF($2,''), $3, 'postgresql', '', 'pending')
		 RETURNING id::text`, tenantID, mount, iso)
	if err != nil {
		return "", fmt.Errorf("backup: insert ledger row: %w", err)
	}
	defer rows.Close()
	if !rows.Next() {
		if rerr := rows.Err(); rerr != nil {
			return "", fmt.Errorf("backup: insert ledger row: %w", rerr)
		}
		return "", fmt.Errorf("backup: insert ledger row returned no id")
	}
	var id string
	if err := rows.Scan(&id); err != nil {
		return "", fmt.Errorf("backup: scan inserted id: %w", err)
	}
	return id, nil
}

// CreateBackup performs a logical export of one tenant's data and records it.
// Flow: resolve+guard isolation -> INSERT status='pending' -> extract->Upload ->
// UPDATE status='completed' (size/sha256) or 'failed' (error_message). Returns
// the backup id. tenant_id is always a bind param.
func (s *Service) CreateBackup(ctx context.Context, tenantID, mount string) (string, error) {
	iso, dsn, err := s.isolationFor(ctx, tenantID, mount)
	if err != nil {
		return "", err
	}
	if err := guardIsolation(iso); err != nil {
		return "", err
	}

	backupID, err := s.insertPending(ctx, tenantID, mount, iso)
	if err != nil {
		return "", err
	}

	key := tenantID + "/" + backupID
	location, size, sha, xerr := s.extractTo(ctx, iso, tenantID, dsn, key)
	if xerr != nil {
		_ = s.db.AdminExec(ctx,
			`UPDATE public.tenant_backups SET status='failed', error_message=$2 WHERE id=$1`,
			backupID, xerr.Error())
		return backupID, xerr
	}
	if uerr := s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups
		    SET status='completed', location=$2, size_bytes=$3, sha256=$4, completed_at=now()
		  WHERE id=$1`, backupID, location, size, sha); uerr != nil {
		return backupID, fmt.Errorf("backup: finalize ledger row: %w", uerr)
	}
	return backupID, nil
}

// extractTo streams the right export into the store under key and returns the
// resolved location/size/sha. It uses an io.Pipe so the COPY stream flows
// straight into Upload without a full-artifact buffer.
func (s *Service) extractTo(ctx context.Context, iso, tenantID, dsn, key string) (string, int64, string, error) {
	pr, pw := io.Pipe()
	go func() {
		var werr error
		switch iso {
		case "schema_per_tenant":
			schema := s.schemaFor(tenantID)
			if schema == "" {
				werr = fmt.Errorf("backup: tenant id %q sanitizes to empty schema", tenantID)
			} else {
				werr = extractSchema(ctx, s.db, schema, pw)
			}
		case "db_per_tenant":
			if dsn == "" {
				werr = fmt.Errorf("backup: db_per_tenant requires a resolved DSN (no resolver wired)")
			} else {
				werr = extractDatabase(ctx, dsn, pw)
			}
		default:
			werr = ErrIsolationDeferred
		}
		_ = pw.CloseWithError(werr)
	}()
	return s.store.Upload(ctx, key, pr)
}

// ListBackups returns the tenant's backups, most-recent-first. tenant_id is a
// bind param; RLS is a second wall for the self-serve read path.
func (s *Service) ListBackups(ctx context.Context, tenantID string) ([]BackupRow, error) {
	rows, err := s.db.AdminQuery(ctx,
		`SELECT id::text, tenant_id, COALESCE(mount,''), isolation, engine, status,
		        size_bytes, COALESCE(sha256,''), created_at::text
		   FROM public.tenant_backups
		  WHERE tenant_id = $1
		  ORDER BY created_at DESC`, tenantID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []BackupRow
	for rows.Next() {
		var b BackupRow
		if err := rows.Scan(&b.ID, &b.TenantID, &b.Mount, &b.Isolation, &b.Engine,
			&b.Status, &b.SizeBytes, &b.SHA256, &b.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// Restore restores a backup into the OWNING tenant only. It loads the row by
// (id, tenant_id) — the load-bearing caller==owner check — BEFORE any DDL; an
// empty result is ErrNotOwned (403/404). It then guards isolation, downloads the
// artifact, and replays into A's OWN schema/db. Status flips restoring->restored
// (or 'failed').
func (s *Service) Restore(ctx context.Context, tenantID, backupID string) error {
	var iso, mount string
	rows, err := s.db.AdminQuery(ctx,
		`SELECT isolation, COALESCE(mount,'')
		   FROM public.tenant_backups
		  WHERE id = $1 AND tenant_id = $2`, backupID, tenantID)
	if err != nil {
		return fmt.Errorf("backup: load row: %w", err)
	}
	found := rows.Next()
	if found {
		if scanErr := rows.Scan(&iso, &mount); scanErr != nil {
			rows.Close()
			return fmt.Errorf("backup: scan row: %w", scanErr)
		}
	}
	rows.Close()
	if rerr := rows.Err(); rerr != nil {
		return fmt.Errorf("backup: load row: %w", rerr)
	}
	if !found {
		// Load-bearing caller==owner: a backup id that is not the caller's (or
		// does not exist) is indistinguishable -> ErrNotOwned (403/404). NO DDL
		// has run at this point.
		return ErrNotOwned
	}
	if err := guardIsolation(iso); err != nil {
		return err
	}
	if err := s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restoring' WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID); err != nil {
		return err
	}

	_, dsn, rerr := s.isolationFor(ctx, tenantID, mount)
	if rerr != nil {
		return rerr
	}
	key := tenantID + "/" + backupID
	if err := s.replayInto(ctx, iso, tenantID, dsn, key); err != nil {
		_ = s.db.AdminExec(ctx,
			`UPDATE public.tenant_backups SET status='failed', error_message=$2 WHERE id=$1`,
			backupID, err.Error())
		return err
	}
	return s.db.AdminExec(ctx,
		`UPDATE public.tenant_backups SET status='restored', completed_at=now() WHERE id=$1 AND tenant_id=$2`,
		backupID, tenantID)
}

// replayInto downloads the artifact and replays it into the tenant's OWN scope.
func (s *Service) replayInto(ctx context.Context, iso, tenantID, dsn, key string) error {
	pr, pw := io.Pipe()
	go func() { _ = pw.CloseWithError(s.store.Download(ctx, key, pw)) }()
	switch iso {
	case "schema_per_tenant":
		schema := s.schemaFor(tenantID)
		if schema == "" {
			return fmt.Errorf("backup: tenant id %q sanitizes to empty schema", tenantID)
		}
		return restoreSchema(ctx, s.db, schema, pr)
	case "db_per_tenant":
		if dsn == "" {
			return fmt.Errorf("backup: db_per_tenant restore requires a resolved DSN (no resolver wired)")
		}
		return restoreDatabase(ctx, dsn, pr)
	default:
		return ErrIsolationDeferred
	}
}
