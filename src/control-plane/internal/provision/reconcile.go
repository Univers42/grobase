package provision

import (
	"context"
	"regexp"
)

// uuidRe gates owner_user_id before it is cast to ::uuid for a role assignment,
// so a non-UUID owner is skipped cleanly (matches tenants.uuidRe semantics).
var uuidRe = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// ── Injected dependency interfaces (all fakeable) ────────────────────────────

// complete/partial (→ 201/200).
func (rc *Reconciler) Reconcile(ctx context.Context, spec StackSpec) (ReconcileResult, error) {
	spec.Normalize()
	if err := spec.Validate(); err != nil {
		return ReconcileResult{}, err
	}

	// Concurrency guard: one in-flight reconcile per slug.
	release, err := rc.acquireSlugLock(ctx, spec.Tenant)
	if err != nil {
		return ReconcileResult{}, err
	}
	defer release()

	res := rc.applyAll(ctx, spec, spec.Compile())
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
	if r.Kind == KindTenant {
		return rc.reconcileTenant(ctx, res, desired, out)
	}
	if blockedOut, isBlocked := blockedFor(r, spec, blocked, roleIDByKey); isBlocked {
		return blockedOut
	}
	switch r.Kind {
	case KindKey:
		return rc.reconcileKey(ctx, res, spec, r, out)
	case KindRole:
		return rc.reconcileRole(ctx, spec, r, out, blocked, roleIDByKey)
	case KindPolicy:
		return rc.reconcilePolicy(ctx, r, out, roleIDByKey[r.RoleRef])
	case KindMount:
		return rc.reconcileMount(ctx, spec, r, out, blocked)
	case KindSchema:
		return rc.reconcileSchema(ctx, spec, r, out)
	default:
		out.Status, out.Error = StatusError, "unknown resource kind"
		return out
	}
}

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
