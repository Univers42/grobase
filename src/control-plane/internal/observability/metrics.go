/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   metrics.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:47:50 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:47:52 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package observability

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// Metrics is a per-process metrics sink, constructed once at main() and injected
// (NewMetrics) — no package-level global. Each control-plane binary runs as its
// own OS process, so one Metrics is naturally scoped to a single service (the
// pattern client_golang's default registry uses, made explicit).
//
// Keeping this dependency-free (no client_golang) is deliberate: the control
// plane's value proposition is tiny, fast-starting static binaries, and the
// daemons only need request counts + a mean-latency gauge visible to Prometheus.
// See wiki/05-orchestration-observability-roadmap.md §2 (G7).
func NewMetrics() *Metrics { return &Metrics{start: time.Now()} }

// tenantSeriesCap is the HARD in-process ceiling on distinct tenant_id series
// the Pillar-3 bounded counter will track. Past the cap, every further tenant
// folds into a single sentinel series tenant_id="_over_cap", so the exposition
// can never exceed tenantSeriesCap+1 tenant series regardless of how many
// tenants the platform serves. This MUST match the Rust data plane's cap
// (DATA_PLANE_TENANT_OBS_COUNTER, N=512) so the two planes' /metrics agree.
const tenantSeriesCap = 512

// overCapSentinel is the single fold-in label value for tenants beyond the cap.
const overCapSentinel = "_over_cap"

type Metrics struct {
	service  string
	start    time.Time
	counts   sync.Map // key "METHOD:Nxx" -> *int64
	sumNs    int64    // cumulative request duration, for a mean gauge
	sumCount int64
	custom   sync.Map // counterID -> *counterEntry (domain counters)

	// Pillar-3 (B5) bounded per-tenant request counter. DELIBERATELY separate
	// from `custom` above: that store is UNBOUNDED (keyed by arbitrary
	// labelVal), so routing tenant_id through IncCounter would be a 10K-tenant
	// cardinality bomb. This dedicated path is hard-capped at tenantSeriesCap
	// distinct sanitized tenant_ids; the rest fold into overCapSentinel. Only
	// touched when TENANT_OBS_COUNTER && TENANT_OBS_ENABLED are both on.
	tenantReq     sync.Map // key "Nxx\x00<sanitized tenant_id>" -> *int64
	tenantSet     sync.Map // sanitized tenant_id -> struct{} (admitted set)
	tenantSetSize int64    // atomic: count of distinct tenant_ids admitted (<= cap)
}

// counterID is the identity of a domain counter: a metric name plus at most one
// label. One label covers the control plane's needs (outcome classes, kinds)
// without dragging in a full label-set registry.
type counterID struct{ name, labelKey, labelVal string }

type counterEntry struct {
	help string
	n    int64
}

func (m *Metrics) SetService(name string) { m.service = name }

// Observe records one finished request. method/status come from the middleware.
func (m *Metrics) Observe(method string, status int, d time.Duration) {
	key := method + ":" + fmt.Sprintf("%dxx", status/100)
	ctr, _ := m.counts.LoadOrStore(key, new(int64))
	atomic.AddInt64(ctr.(*int64), 1)
	atomic.AddInt64(&m.sumNs, d.Nanoseconds())
	atomic.AddInt64(&m.sumCount, 1)
}
