/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   otlp.go                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:47 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:48 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package telemetryexport

import (
	"encoding/json"
	"strconv"
	"time"
)

// buildOTLP emits a minimal but valid OTLP/HTTP logs JSON envelope. tenant_id is a
// RESOURCE attribute (so the whole batch is attributed to the tenant) AND a
// per-record attribute (so an aggregating collector can filter per record). The
// envelope shape follows the OTLP/HTTP JSON encoding for ExportLogsServiceRequest.
func (e *Exporter) buildOTLP(tenantID string, rows []usageRow) []byte {
	logRecords := make([]map[string]any, 0, len(rows))
	for _, u := range rows {
		logRecords = append(logRecords, otlpLogRecord(tenantID, u))
	}
	env := map[string]any{
		"resourceLogs": []map[string]any{{
			"resource": map[string]any{
				"attributes": []map[string]any{
					kv("service.name", strVal("grobase")),
					kv("tenant_id", strVal(tenantID)),
				},
			},
			"scopeLogs": []map[string]any{{
				"scope":      map[string]any{"name": "grobase.telemetry-export"},
				"logRecords": logRecords,
			}},
		}},
	}
	out, _ := json.Marshal(env)
	return out
}

// otlpLogRecord builds one OTLP LogRecord for a usage row, carrying tenant_id as a
// per-record attribute so an aggregating collector can filter per record.
func otlpLogRecord(tenantID string, u usageRow) map[string]any {
	nano := strconv.FormatInt(u.windowStart.UTC().UnixNano(), 10)
	return map[string]any{
		"timeUnixNano": nano,
		"severityText": "INFO",
		"body":         map[string]any{"stringValue": "tenant_usage"},
		"attributes": []map[string]any{
			kv("tenant_id", strVal(tenantID)),
			kv("metric", strVal(u.metric)),
			kv("qty", intVal(u.qty)),
			kv("window_start", strVal(u.windowStart.UTC().Format(time.RFC3339))),
		},
	}
}

// kv builds one OTLP KeyValue attribute.
func kv(key string, value map[string]any) map[string]any {
	return map[string]any{"key": key, "value": value}
}

// strVal / intVal build OTLP AnyValue scalars.
func strVal(s string) map[string]any { return map[string]any{"stringValue": s} }
func intVal(n int64) map[string]any  { return map[string]any{"intValue": strconv.FormatInt(n, 10)} }
