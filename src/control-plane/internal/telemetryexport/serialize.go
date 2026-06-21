/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   serialize.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:53 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:55 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package telemetryexport

import (
	"encoding/json"
	"strings"
	"time"
)

// buildBatch serializes one tenant's usage rows for delivery, ALWAYS tagging every
// record with tenant_id (the C9 attribution invariant). Two wire shapes:
//
//   - "otlp"  : an OTLP/HTTP logs JSON envelope — one resource with a tenant_id
//     resource attribute, one LogRecord per usage row carrying metric/qty/window.
//     This is what an OpenTelemetry Collector's OTLP/HTTP logs receiver accepts.
//   - "ndjson": newline-delimited JSON, one {tenant_id, metric, qty, window} object
//     per line — the lowest-common-denominator log-drain shape (Loki push proxies,
//     Vector, Datadog/Logtail HTTP intakes, etc.).
//
// Returns the body and its Content-Type. An unknown format falls back to otlp (the
// default), so a typo can never silently drop the tenant_id attribution.
func (e *Exporter) buildBatch(t target, rows []usageRow) ([]byte, string) {
	if strings.EqualFold(t.format, "ndjson") {
		return e.buildNDJSON(t.tenantID, rows), "application/x-ndjson"
	}
	return e.buildOTLP(t.tenantID, rows), "application/json"
}

// buildNDJSON emits one JSON object per usage row, each tagged with tenant_id.
func (e *Exporter) buildNDJSON(tenantID string, rows []usageRow) []byte {
	var b strings.Builder
	for _, u := range rows {
		rec := map[string]any{
			"tenant_id":    tenantID,
			"source":       "grobase.tenant_usage",
			"metric":       u.metric,
			"qty":          u.qty,
			"window_start": u.windowStart.UTC().Format(time.RFC3339),
		}
		line, _ := json.Marshal(rec)
		b.Write(line)
		b.WriteByte('\n')
	}
	return []byte(b.String())
}
