/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   velocity.go                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:38:17 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:38:18 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package abuseguard

import (
	"context"
	"fmt"
	"time"
)

const countVelocitySQL = `
SELECT COUNT(*)::bigint
  FROM public.principal_events
 WHERE principal = $1 AND action = $2 AND created_at >= $3`

const insertVelocitySQL = `
INSERT INTO public.principal_events (principal, tenant_id, action) VALUES ($1, $2, $3)`

// velocityLimited reports whether an action is velocity-tracked. Today only
// project_create; adding one is a single case.
func (g *Guard) velocityLimited(action string) bool {
	return action == ActionProjectCreate
}

// velocityGate enforces the per-principal sliding-window limit for a velocity-tracked
// action. It returns (denyResult, ok, err): ok=false carries the velocity_exceeded
// deny (and auto-suspends the tenant when configured, since a breach is a strong
// abuse signal). On admit it RECORDS the event so the next call counts it — a record
// failure is logged, not propagated (failing closed on a ledger write would turn a
// transient DB blip into a free-tier outage).
func (g *Guard) velocityGate(ctx context.Context, principal, tenant, action string) (AdmitResult, bool, error) {
	breached, err := g.velocityBreached(ctx, principal, action)
	if err != nil {
		return AdmitResult{}, false, fmt.Errorf("abuse: velocity check: %w", err)
	}
	if breached {
		if g.autoSuspend {
			if serr := g.setSuspended(ctx, tenant, true, "velocity:"+action); serr != nil {
				g.log.Warn("abuse: auto-suspend on velocity breach failed", "tenant", tenant, "err", serr)
			}
		}
		return AdmitResult{Admit: false, Reason: "velocity_exceeded", Suspended: g.autoSuspend}, false, nil
	}
	if err := g.db.AdminExec(ctx, insertVelocitySQL, principal, tenant, action); err != nil {
		g.log.Warn("abuse: record velocity event failed (admission still granted)", "principal", principal, "err", err)
	}
	return AdmitResult{}, true, nil
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
