package abuseguard

import (
	"context"
	"fmt"
	"time"
)

// AdmitResult is the outcome of an admission check.
type AdmitResult struct {
	Admit  bool   `json:"admit"`
	Reason string `json:"reason,omitempty"` // machine code when denied
	// Suspended echoes whether the deny was because the tenant is suspended (so a
	// caller can distinguish a hard suspend from a transient velocity/verify deny).
	Suspended bool `json:"suspended,omitempty"`
}

// safetyRow is the tenant_safety state the guard reads for an admission decision.
// Absent row → the zero value (not suspended, nothing verified) → the parity
// default (an enabled guard still admits a tier with NO requirement).
type safetyRow struct {
	emailVerified bool
	phoneVerified bool
	payMethod     bool
	suspended     bool
}

const selectSafetySQL = `
SELECT email_verified, phone_verified, pay_method, suspended
  FROM public.tenant_safety
 WHERE tenant_id = $1`

// readSafety loads the tenant_safety row; a missing row returns the zero value
// (the parity default), NOT an error.
func (g *Guard) readSafety(ctx context.Context, tenantID string) (safetyRow, error) {
	rows, err := g.db.AdminQuery(ctx, selectSafetySQL, tenantID)
	if err != nil {
		return safetyRow{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		return safetyRow{}, rows.Err() // no row → parity default
	}
	var s safetyRow
	if err := rows.Scan(&s.emailVerified, &s.phoneVerified, &s.payMethod, &s.suspended); err != nil {
		return safetyRow{}, err
	}
	return s, nil
}

const countVelocitySQL = `
SELECT COUNT(*)::bigint
  FROM public.principal_events
 WHERE principal = $1 AND action = $2 AND created_at >= $3`

const insertVelocitySQL = `
INSERT INTO public.principal_events (principal, tenant_id, action) VALUES ($1, $2, $3)`

// Admit decides whether `principal` (api-key:<uuid> / user:<id>) may take `action`
// for `tenant` on `tier`. The order is fail-FAST on the hardest signal first:
//
//  1. SUSPENDED tenant → deny (the strongest block).
//  2. VERIFICATION gate for the tier (email/phone/pay) → deny if a required signal
//     is missing.
//  3. VELOCITY: count the principal's recent same-action events; over the limit →
//     deny (and auto-suspend the tenant if configured, since a velocity breach is a
//     strong abuse signal).
//
// On ADMIT for a velocity-tracked action, the call is RECORDED in principal_events
// so the next call sees it (the ledger is the velocity source of truth). A record
// failure is logged but does NOT deny an otherwise-admitted call (failing closed on
// a ledger write would turn a transient DB blip into a free-tier outage; the next
// tick's count is at worst one short, which is conservative-toward-allow only by 1).
func (g *Guard) Admit(ctx context.Context, principal, tenant, tier, action string) (AdmitResult, error) {
	if principal == "" || tenant == "" || action == "" {
		return AdmitResult{Admit: false, Reason: "invalid_request"}, nil
	}

	safety, err := g.readSafety(ctx, tenant)
	if err != nil {
		return AdmitResult{}, fmt.Errorf("abuse: read safety: %w", err)
	}
	if safety.suspended {
		return AdmitResult{Admit: false, Reason: "tenant_suspended", Suspended: true}, nil
	}

	if reason, ok := g.verificationGate(tier, safety); !ok {
		return AdmitResult{Admit: false, Reason: reason}, nil
	}

	if g.velocityLimited(action) {
		breached, err := g.velocityBreached(ctx, principal, action)
		if err != nil {
			return AdmitResult{}, fmt.Errorf("abuse: velocity check: %w", err)
		}
		if breached {
			if g.autoSuspend {
				if serr := g.setSuspended(ctx, tenant, true, "velocity:"+action); serr != nil {
					g.log.Warn("abuse: auto-suspend on velocity breach failed", "tenant", tenant, "err", serr)
				}
			}
			return AdmitResult{Admit: false, Reason: "velocity_exceeded", Suspended: g.autoSuspend}, nil
		}
		// Admitted: record the event so the next call counts it.
		if err := g.db.AdminExec(ctx, insertVelocitySQL, principal, tenant, action); err != nil {
			g.log.Warn("abuse: record velocity event failed (admission still granted)", "principal", principal, "err", err)
		}
	}

	return AdmitResult{Admit: true}, nil
}

// verificationGate reports whether the tenant satisfies the tier's verification
// requirement. A tier with NO configured requirement (the parity default) always
// passes. Returns (reason, ok): ok=false carries the missing-signal reason.
func (g *Guard) verificationGate(tier string, s safetyRow) (string, bool) {
	req, ok := g.tierReqs[tier]
	if !ok {
		return "", true // no requirement for this tier → parity
	}
	if req.email && !s.emailVerified {
		return "email_unverified", false
	}
	if req.phone && !s.phoneVerified {
		return "phone_unverified", false
	}
	if req.payMethod && !s.payMethod {
		return "pay_method_required", false
	}
	return "", true
}

// velocityLimited reports whether an action is velocity-tracked. Today only
// project_create; adding one is a single case.
func (g *Guard) velocityLimited(action string) bool {
	return action == ActionProjectCreate
}

// velocityBreached counts the principal's same-action events in the sliding window
// and reports whether the NEXT one would exceed the max (count >= max → breach, so
// the (max+1)th is denied; with max=20, the 21st call is the first denied).
func (g *Guard) velocityBreached(ctx context.Context, principal, action string) (bool, error) {
	since := time.Now().UTC().Add(-g.velocityWindow)
	rows, err := g.db.AdminQuery(ctx, countVelocitySQL, principal, action, since)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	var n int64
	if rows.Next() {
		if err := rows.Scan(&n); err != nil {
			return false, err
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	return n >= int64(g.velocityMax), nil
}
