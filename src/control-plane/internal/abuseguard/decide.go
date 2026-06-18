package abuseguard

import (
	"context"
	"fmt"
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
		return safetyRow{}, rows.Err()
	}
	var s safetyRow
	if err := rows.Scan(&s.emailVerified, &s.phoneVerified, &s.payMethod, &s.suspended); err != nil {
		return safetyRow{}, err
	}
	return s, nil
}

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
		if res, ok, err := g.velocityGate(ctx, principal, tenant, action); err != nil || !ok {
			return res, err
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
		return "", true
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
