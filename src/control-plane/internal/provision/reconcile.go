package provision

import (
	"context"
	"errors"
	"log/slog"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// uuidRe gates owner_user_id before it is cast to ::uuid for a role assignment,
// so a non-UUID owner is skipped cleanly (matches tenants.uuidRe semantics).
var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// ── Injected dependency interfaces (all fakeable) ────────────────────────────

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
// complete/partial (→ 201/200).
func (rc *Reconciler) Reconcile(ctx context.Context, spec StackSpec) (ReconcileResult, error) {
	spec.Normalize()
	if err := spec.Validate(); err != nil {
		return ReconcileResult{}, err
	}

	// Concurrency guard: one in-flight reconcile per slug.
	if rc.Lock != nil {
		release, ok, err := rc.Lock.TryLock(ctx, spec.Tenant)
		if err != nil {
			return ReconcileResult{}, err
		}
		if !ok {
			return ReconcileResult{}, ErrBusy
		}
		defer release()
	}

	desired := spec.Compile()
	res := ReconcileResult{Resources: make([]ResourceResult, 0, len(desired.Resources))}

	// blocked tracks resource Keys whose prerequisite failed. A dependent of a
	// blocked/failed parent is itself marked blocked (no downstream write).
	blocked := map[string]bool{}
	// roleIDByKey resolves a policy's parent role to its DB id once observed.
	roleIDByKey := map[string]string{}

	for _, r := range desired.Resources {
		out := rc.applyOne(ctx, &res, spec, desired, r, blocked, roleIDByKey)
		res.Resources = append(res.Resources, out)
	}

	res.Outcome = classify(res.Resources)
	return res, nil
}

// applyOne reconciles a single resource. It is the only place that performs
// downstream writes, and it reads identity/parents from the resource — never a
// bare literal.
func (rc *Reconciler) applyOne(
	ctx context.Context,
	res *ReconcileResult,
	spec StackSpec,
	desired DesiredState,
	r Resource,
	blocked map[string]bool,
	roleIDByKey map[string]string,
) ResourceResult {
	out := ResourceResult{Kind: kindName(r.Kind), Key: r.Key}

	switch r.Kind {
	case KindTenant:
		return rc.reconcileTenant(ctx, res, desired, out)
	case KindKey:
		if blocked[TenantKey(spec.Tenant)] {
			out.Status, out.Action = StatusBlocked, ""
			return out
		}
		return rc.reconcileKey(ctx, res, spec, r, out)
	case KindRole:
		if blocked[TenantKey(spec.Tenant)] {
			out.Status = StatusBlocked
			return out
		}
		return rc.reconcileRole(ctx, spec, r, out, blocked, roleIDByKey)
	case KindPolicy:
		if blocked[r.RoleRef] || roleIDByKey[r.RoleRef] == "" {
			out.Status = StatusBlocked
			return out
		}
		return rc.reconcilePolicy(ctx, r, out, roleIDByKey[r.RoleRef])
	case KindMount:
		if blocked[TenantKey(spec.Tenant)] {
			out.Status = StatusBlocked
			return out
		}
		return rc.reconcileMount(ctx, spec, r, out, blocked)
	case KindSchema:
		if blocked[r.Key2] {
			out.Status = StatusBlocked
			return out
		}
		return rc.reconcileSchema(ctx, spec, r, out)
	default:
		out.Status = StatusError
		out.Error = "unknown resource kind"
		return out
	}
}

func (rc *Reconciler) reconcileTenant(ctx context.Context, res *ReconcileResult, d DesiredState, out ResourceResult) ResourceResult {
	info, exists, err := rc.Tenants.GetTenant(ctx, d.Slug)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if exists {
		res.Tenant = info
		out.Action, out.Status, out.ID = string(ActionNoOp), StatusExists, info.Slug
		return out
	}
	// Thread the requested billing plan (default "free") so a provision that
	// asks for e.g. `pro` actually lands a pro tenant — without this the plan
	// field was silently dropped and every tenant defaulted to free, which is
	// why the scale experiment had to disable PACKAGE_ENFORCEMENT to register
	// non-sqlite mounts.
	created, err := rc.Tenants.CreateTenant(ctx, d.Slug, d.Name, d.OwnerUser, d.Plan)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	res.Tenant = created
	out.Action, out.Status, out.ID = string(ActionCreate), StatusCreated, created.Slug
	return out
}

func (rc *Reconciler) reconcileKey(ctx context.Context, res *ReconcileResult, spec StackSpec, r Resource, out ResourceResult) ResourceResult {
	k := r.Key3
	has, err := rc.Tenants.ActiveKeyExists(ctx, spec.Tenant, k.Name)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if has {
		// Idempotent: never re-mint a live secret.
		out.Action, out.Status, out.Detail = string(ActionNoOp), StatusExists, k.Name
		return out
	}
	issued, err := rc.Tenants.IssueAPIKey(ctx, spec.Tenant, k)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if res.APIKey == nil {
		ki := issued
		res.APIKey = &ki
	}
	out.Action, out.Status, out.ID, out.Detail = string(ActionCreate), StatusCreated, issued.ID, k.Name
	return out
}

func (rc *Reconciler) reconcileRole(ctx context.Context, spec StackSpec, r Resource, out ResourceResult, blocked map[string]bool, roleIDByKey map[string]string) ResourceResult {
	roleID, created, err := rc.Perm.EnsureRole(ctx, spec.Tenant, r.Role)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		blocked[r.Key] = true
		return out
	}
	roleIDByKey[r.Key] = roleID
	out.ID = roleID
	out.Detail = NamespacedRoleName(r.Key)

	// Assign the role to the owner if it is a UUID (mirrors prior seed semantics).
	if uuidRe.MatchString(spec.OwnerUserID) {
		if aerr := rc.Perm.AssignRole(ctx, spec.OwnerUserID, NamespacedRoleName(r.Key)); aerr != nil {
			out.Status, out.Error = StatusError, aerr.Error()
			blocked[r.Key] = true
			return out
		}
	}
	if created {
		out.Action, out.Status = string(ActionCreate), StatusCreated
	} else {
		out.Action, out.Status = string(ActionNoOp), StatusExists
	}
	return out
}

func (rc *Reconciler) reconcilePolicy(ctx context.Context, r Resource, out ResourceResult, roleID string) ResourceResult {
	created, err := rc.Perm.EnsurePolicy(ctx, roleID, r.Policy)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	if created {
		out.Action, out.Status = string(ActionCreate), StatusCreated
	} else {
		out.Action, out.Status = string(ActionNoOp), StatusExists
	}
	return out
}

func (rc *Reconciler) reconcileMount(ctx context.Context, spec StackSpec, r Resource, out ResourceResult, blocked map[string]bool) ResourceResult {
	e := r.Engine
	if !D().SupportedMountIsolation[e.Isolation] {
		// e.g. db_per_tenant — declared but not realisable here. Surface it
		// explicitly (NOT a silent skip) and block the dependent schema step.
		out.Status, out.Detail = StatusUnsupported, e.Isolation
		blocked[r.Key] = true
		return out
	}
	if rc.Mounts == nil {
		out.Status, out.Error = StatusError, "mount client not configured"
		blocked[r.Key] = true
		return out
	}
	id, status, err := rc.Mounts.RegisterMount(ctx, spec.Tenant, e)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		blocked[r.Key] = true
		return out
	}
	out.ID = id
	switch status {
	case "created":
		out.Action, out.Status = string(ActionCreate), StatusCreated
	default: // "exists"
		out.Action, out.Status = string(ActionNoOp), StatusExists
	}
	return out
}

func (rc *Reconciler) reconcileSchema(ctx context.Context, spec StackSpec, r Resource, out ResourceResult) ResourceResult {
	e := r.Engine
	if !strings.EqualFold(e.Engine, "postgresql") {
		out.Status, out.Error = StatusError, "schema_per_tenant only supported for postgresql mounts"
		return out
	}
	if rc.Schemas == nil {
		out.Status, out.Error = StatusError, "schema client not configured"
		return out
	}
	schema, err := rc.Schemas.EnsureSchema(ctx, spec.Tenant, e)
	if err != nil {
		out.Status, out.Error = StatusError, err.Error()
		return out
	}
	// CREATE SCHEMA IF NOT EXISTS is a no-op when present; the data plane does
	// not distinguish created vs existed, so we report it as ensured (exists).
	out.Action, out.Status, out.Detail = string(ActionNoOp), StatusExists, schema
	return out
}

// classify folds per-resource statuses into the overall outcome. Only a failed
// TENANT step is fatal (5xx). Any other non-converged status (error, blocked,
// or unsupported) → partial (retryable / surfaced, 200). A clean stack →
// complete.
func classify(rs []ResourceResult) string {
	anyGap := false
	for _, r := range rs {
		if r.Kind == kindName(KindTenant) && r.Status == StatusError {
			return OutcomeFailed
		}
		switch r.Status {
		case StatusError, StatusBlocked, StatusUnsupported:
			anyGap = true
		}
	}
	if anyGap {
		return OutcomePartial
	}
	return OutcomeComplete
}

func kindName(k Kind) string {
	switch k {
	case KindTenant:
		return "tenant"
	case KindKey:
		return "key"
	case KindRole:
		return "role"
	case KindPolicy:
		return "policy"
	case KindMount:
		return "mount"
	case KindSchema:
		return "schema"
	default:
		return "unknown"
	}
}

// ── Postgres advisory-lock Locker ────────────────────────────────────────────

// SQL fragments for the session-scoped advisory lock. Centralized so the
// acquire/release pair (which MUST run on the same connection) stays in lockstep
// and uses the same hashtext key derivation.
const (
	sqlTryAdvisoryLock = `SELECT pg_try_advisory_lock(hashtext('provision:' || $1))`
	sqlAdvisoryUnlock  = `SELECT pg_advisory_unlock(hashtext('provision:' || $1))`
)

// PoolConn is one checked-out connection. *pgxpool.Conn satisfies it. Because a
// session advisory lock is bound to the backend connection that took it, the
// locker MUST acquire AND release on the SAME PoolConn — the pool-level
// DB/AdminQuery/AdminExec abstraction cannot express that affinity.
type PoolConn interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Release()
}

// ConnAcquirer hands out a dedicated connection for the lock's whole lifetime.
// *shared.Postgres satisfies it via AcquireConn.
type ConnAcquirer interface {
	AcquireConn(ctx context.Context) (*pgxpool.Conn, error)
}

// connAcquirer adapts a ConnAcquirer to return the PoolConn interface so the
// locker logic stays decoupled from *pgxpool.Conn (and unit-testable with a fake).
type connAcquirerFunc func(ctx context.Context) (PoolConn, error)

func (f connAcquirerFunc) acquire(ctx context.Context) (PoolConn, error) { return f(ctx) }

type connSource interface {
	acquire(ctx context.Context) (PoolConn, error)
}

// pgLocker implements Locker via a CONNECTION-AFFINE session advisory lock: it
// pins one connection for the entire reconcile, takes pg_try_advisory_lock on
// it, and releases the lock + the connection together. This actually serializes
// concurrent same-slug reconciles (the prior pool-level impl did not — acquire
// and release landed on different pooled connections, making it a no-op).
type pgLocker struct{ src connSource }

// NewPGLocker builds a connection-affine Postgres advisory-lock Locker.
func NewPGLocker(src ConnAcquirer) Locker {
	return newPGLockerWithSource(connAcquirerFunc(func(ctx context.Context) (PoolConn, error) {
		return src.AcquireConn(ctx)
	}))
}

// newPGLockerWithSource is the testable seam: it takes a connSource directly so a
// fake PoolConn can verify acquire/release land on the SAME connection (real
// connection affinity) without a live Postgres.
func newPGLockerWithSource(src connSource) Locker { return &pgLocker{src: src} }

func (l *pgLocker) TryLock(ctx context.Context, slug string) (func(), bool, error) {
	conn, err := l.src.acquire(ctx)
	if err != nil {
		return nil, false, err
	}
	rows, err := conn.Query(ctx, sqlTryAdvisoryLock, slug)
	if err != nil {
		conn.Release()
		return nil, false, err
	}
	var ok bool
	if scanErr := scanBool(rows, &ok); scanErr != nil {
		conn.Release()
		return nil, false, scanErr
	}
	if !ok {
		// Lock held elsewhere → fast-fail to 409. Return the connection
		// immediately; we never took the lock so there is nothing to unlock.
		conn.Release()
		return nil, false, nil
	}
	release := func() {
		// Release the lock on the SAME connection that holds it, THEN return the
		// connection to the pool. A fresh background ctx so unlock still runs when
		// the request ctx is already cancelled; the session lock also drops on
		// conn close, so this is belt-and-suspenders.
		_, _ = conn.Exec(context.Background(), sqlAdvisoryUnlock, slug)
		conn.Release()
	}
	return release, true, nil
}

func scanBool(rows pgx.Rows, dst *bool) error {
	defer rows.Close()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return rows.Scan(dst)
}

// HTTPStatus maps an outcome to its HTTP status code. Centralized so handler +
// tests agree on the mapping.
func HTTPStatus(outcome string, freshKey bool) int {
	switch outcome {
	case OutcomeFailed:
		return 500
	case OutcomePartial:
		return 200
	default: // complete
		if freshKey {
			return 201
		}
		return 200
	}
}
