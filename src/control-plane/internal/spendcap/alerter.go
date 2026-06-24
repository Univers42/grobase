/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   alerter.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:55:59 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:56:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package spendcap

import (
	"context"
	"log/slog"
)

// logAlerter is the default alerter: it emits the 80% budget ALERT as a structured
// WARN log line. Routing that alert to a human channel (email/PagerDuty/webhook) is
// a B7.5 dunning/notification concern, deliberately OUT of this safety slice — the
// guard's job is to DECIDE the alert once per period; delivery is pluggable. A
// deployment that wires a real notifier injects it via SetAlerter before Init.
type logAlerter struct{ log *slog.Logger }

// BudgetAlert logs the once-per-period soft alert. tenant_id is a structured field
// (cardinality-safe, matching the B5 per-tenant-obs convention: tenant_id is a log
// FIELD, never a Prometheus label).
func (a logAlerter) BudgetAlert(_ context.Context, tenantID string, spentCents, budgetCents int64, pct int) {
	a.log.Warn(
		"spend-cap budget alert",
		"tenant_id", tenantID,
		"spent_cents", spentCents,
		"budget_cents", budgetCents,
		"pct", pct,
	)
}

// SetAlerter overrides the default log-only alerter (e.g. to wire a notifier or a
// test capture). Optional; called before Init.
func (g *Guard) SetAlerter(a alerter) {
	if a != nil {
		g.alerter = a
	}
}
