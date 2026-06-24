/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   lifecycle.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:57:45 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:57:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package telemetryexport

import (
	"context"
	"time"
)

// SetSink overrides the default HTTP sink (used by the unit test to capture
// deliveries). Optional; called before Init.
func (e *Exporter) SetSink(s sink) {
	if s != nil {
		e.sink = s
	}
}

// Init validates config ONLY when enabled. Disabled ⇒ no connection, no read ⇒
// parity. The HTTP client carries the per-delivery timeout so a slow/hung customer
// collector can never wedge the export loop.
func (e *Exporter) Init(_ context.Context) error {
	if !e.enabled {
		e.log.Info("telemetry export disabled (TENANT_TELEMETRY_EXPORT_ENABLED off) — no export")
		return nil
	}
	if e.batchRows <= 0 {
		e.batchRows = 500
	}
	if e.timeout <= 0 {
		e.timeout = 5 * time.Second
	}
	if hs, ok := e.sink.(*httpSink); ok {
		hs.client.Timeout = e.timeout
	}
	e.log.Info("telemetry export enabled", "interval", e.interval,
		"batch_rows", e.batchRows, "timeout", e.timeout)
	return nil
}

// Run is the export loop: every interval, forward each opted-in tenant's new usage
// to its collector. Disabled ⇒ returns immediately ⇒ parity. Stops on ctx
// cancellation. An export error for one tenant is logged and that tenant's cursor
// is left unadvanced (retried next tick) — a transient blip on one tenant's
// collector never aborts the whole sweep nor wedges other tenants.
func (e *Exporter) Run(ctx context.Context) {
	if !e.enabled {
		return
	}
	e.exportOnce(ctx)
	t := time.NewTicker(e.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			e.exportOnce(ctx)
		}
	}
}
