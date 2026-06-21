/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   billing_catalog.go                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:46:43 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:46:45 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package metering

import (
	"sort"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
)

// billingCatalog (Track-B B3) maps a B1 usage metric name → the Stripe billing
// meter `event_name` to report it under. It is resolved from env
// (BILLING_METER_<METRIC>) rather than packages.json: Stripe meter/price ids are
// per-DEPLOYMENT (a test-mode meter ≠ a live-mode meter) and must not live in the
// repo or in the byte-identical packages.json (m28). A metric with no configured
// event_name is simply NOT billed — the reporter skips it — so billing is opt-in
// per dimension and the default (nothing configured) bills nothing.
type billingCatalog struct {
	meters map[string]string // B1 metric → Stripe meter event_name
}

// loadBillingCatalog reads the BILLING_METER_* env into a metric→event_name map.
// Only metrics with a non-empty event_name are included (opt-in per dimension).
func loadBillingCatalog() billingCatalog {
	metrics := billableMetrics()
	m := make(map[string]string, len(metrics))
	for _, metric := range metrics {
		if name := config.EnvStr(billableMetricEnv(metric), ""); name != "" {
			m[metric] = name
		}
	}
	return billingCatalog{meters: m}
}

// eventName returns the Stripe meter event_name for a metric and whether it is
// billable (configured). A non-billable metric → ("", false) → skipped.
func (c billingCatalog) eventName(metric string) (string, bool) {
	n, ok := c.meters[metric]
	return n, ok
}

// metrics returns the configured billable metric names, sorted for a stable SQL
// `= ANY($2)` argument and deterministic logging.
func (c billingCatalog) metrics() []string {
	out := make([]string, 0, len(c.meters))
	for k := range c.meters {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// empty reports whether nothing is configured to bill (BILLING_ENABLED with an
// empty catalog is a misconfiguration the reporter rejects at Init).
func (c billingCatalog) empty() bool { return len(c.meters) == 0 }
