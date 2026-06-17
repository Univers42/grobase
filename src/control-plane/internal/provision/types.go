package provision

import (
	"context"
	"errors"
	"log/slog"
)

// TenantService is the tenant-row + API-key surface the reconciler needs. The
// concrete impl is an adapter over internal/tenants.Service.
type TenantService interface {
	GetTenant(ctx context.Context, slug string) (TenantInfo, bool, error)
	CreateTenant(ctx context.Context, slug, name, ownerUserID, plan string) (TenantInfo, error)
	ActiveKeyExists(ctx context.Context, slug, keyName string) (bool, error)
	IssueAPIKey(ctx context.Context, slug string, k KeySpec) (KeyInfo, error)
}

// MountClient registers a data mount (adapter-registry).
type MountClient interface {
	RegisterMount(ctx context.Context, slug string, e EngineSpec) (id, status string, err error)
}

// SchemaClient creates a per-tenant schema (Rust data plane).
type SchemaClient interface {
	EnsureSchema(ctx context.Context, slug string, e EngineSpec) (schema string, err error)
}

// Locker guards concurrent reconciles of the same slug (Postgres advisory lock).
type Locker interface {
	TryLock(ctx context.Context, slug string) (release func(), ok bool, err error)
}

// TenantInfo / KeyInfo are the slim views the reconciler reports back.
type TenantInfo struct {
	Slug        string         `json:"id"`
	UUID        string         `json:"uuid,omitempty"`
	Name        string         `json:"name,omitempty"`
	Status      string         `json:"status,omitempty"`
	Plan        string         `json:"plan,omitempty"`
	OwnerUserID *string        `json:"owner_user_id,omitempty"`
	Metadata    map[string]any `json:"metadata,omitempty"`
}

// KeyInfo carries the cleartext key ONCE (only present when freshly minted).
type KeyInfo struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	KeyPrefix string   `json:"key_prefix"`
	Scopes    []string `json:"scopes"`
	Key       string   `json:"key,omitempty"`
}

// ── State + result types ─────────────────────────────────────────────────────

// ActionType is what the reconciler decided to do for a resource.
type ActionType string

const (
	ActionCreate ActionType = "create"
	ActionNoOp   ActionType = "noop"
	ActionUpdate ActionType = "update"
)

// Per-resource status surfaced to the caller.
const (
	StatusCreated     = "created"
	StatusExists      = "exists"
	StatusUpdated     = "updated"
	StatusError       = "error"
	StatusBlocked     = "blocked"     // a prerequisite failed; not attempted
	StatusUnsupported = "unsupported" // declared but not realisable (e.g. db_per_tenant)
)

// Overall reconcile outcome.
const (
	OutcomeComplete = "complete"
	OutcomePartial  = "partial"
	OutcomeFailed   = "failed"
)

// ResourceResult is the per-resource reconcile outcome.
type ResourceResult struct {
	Kind   string `json:"kind"`
	Key    string `json:"key"`
	Action string `json:"action,omitempty"`
	Status string `json:"status"`
	ID     string `json:"id,omitempty"`
	Detail string `json:"detail,omitempty"` // schema name, role name, etc.
	Error  string `json:"error,omitempty"`
}

// ReconcileResult is the whole reconcile outcome.
type ReconcileResult struct {
	Tenant    TenantInfo       `json:"tenant"`
	APIKey    *KeyInfo         `json:"api_key,omitempty"`
	Outcome   string           `json:"outcome"`
	Resources []ResourceResult `json:"resources"`
}

// ErrBusy signals another reconcile holds the slug's advisory lock → 409.
var ErrBusy = errors.New("provision already in progress for this tenant")

// Reconciler is the provisioning brain. Deps are interfaces so it is fully
// unit-testable; the live wiring is in cmd/tenant-control.
type Reconciler struct {
	Tenants TenantService
	Perm    PermissionEngine
	Mounts  MountClient
	Schemas SchemaClient
	Lock    Locker
	Log     *slog.Logger
}

// Reconcile drives a StackSpec to its desired state. FORWARD-ONLY: there is no
// rollback — a partial failure leaves prior steps in place and a re-run fixes
// the gap. Steps are applied in Compile()'s fixed topo order (Kind ascending).
//
// Returns (result, http-class). The http class is encoded via the Outcome: only
// a failed TENANT step yields OutcomeFailed (→ 5xx). Everything else is
