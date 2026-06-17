package tenants

import (
	"errors"
	"log/slog"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
	"github.com/dlesieur/mini-baas/control-plane/internal/provision"
)

// ErrNotFound is returned when a tenant or key row doesn't exist.
var ErrNotFound = errors.New("tenant not found")

// ErrConflict is returned on (tenant_id) or (tenant_id, key name) uniqueness violation.
var ErrConflict = errors.New("tenant already exists")

// Service implements tenant lifecycle CRUD + key issuance.
type Service struct {
	db        *pg.Postgres
	log       *slog.Logger
	adapter   *AdapterRegistry           // optional; enables mount reconciliation in Provision
	dataPlane *DataPlane                 // optional; enables schema_per_tenant schema creation
	perm      provision.PermissionEngine // optional; the single ABAC role/policy seam
	verifyC   *verifyCache               // B4-verify: Argon2-only-on-first-seen fast path
}

// NewService wires the DB pool. The PermissionEngine seam defaults to the
// SQL backend over the same admin pool (no HTTP decide), so seedDefaultRole has
// exactly one role implementation. SetPermissionEngine can override it.
func NewService(db *pg.Postgres, log *slog.Logger) *Service {
	return &Service{db: db, log: log, perm: provision.NewSQLBackend(db, "", ""), verifyC: newVerifyCache()}
}

// SetPermissionEngine overrides the ABAC seam (e.g. to enable HTTP self-verify).
func (s *Service) SetPermissionEngine(p provision.PermissionEngine) { s.perm = p }

// SetAdapterRegistry wires the adapter-registry client used by Provision to
// register tenant data mounts. Optional — without it Provision still bootstraps
// the tenant but reports each requested mount as an error.
func (s *Service) SetAdapterRegistry(ar *AdapterRegistry) {
	s.adapter = ar
}

// SetDataPlane wires the Rust data-plane client used by Provision to create the
// per-tenant schema for schema_per_tenant mounts. Optional.
func (s *Service) SetDataPlane(dp *DataPlane) {
	s.dataPlane = dp
}

// AdapterClient returns the wired adapter-registry client (or nil if none). The
// dynamic-builder API (MountBuilder) reuses it for caller-scoped mount CRUD,
// rather than constructing a second client — one source of the adapter-registry
// URL + service token.
func (s *Service) AdapterClient() *AdapterRegistry { return s.adapter }
