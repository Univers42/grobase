package observability

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync/atomic"
)

// trow is one collected per-tenant request-series row.
type trow struct {
	status, tenant string
	n              int64
}

// sanitizeTenantLabel mirrors the Rust data plane's escape_label so a tenant_id
// used as a Prometheus label value can never break the exposition or smuggle an
// extra label. Order matches Rust: backslash first, then double-quote, then
// newline — keeping the two planes' label values byte-identical.
func sanitizeTenantLabel(v string) string {
	v = strings.ReplaceAll(v, `\`, `\\`)
	v = strings.ReplaceAll(v, `"`, `\"`)
	v = strings.ReplaceAll(v, "\n", `\n`)
	return v
}

// ObserveTenant is the Pillar-3 (B5) bounded per-tenant request counter. It is a
// NO-OP unless TENANT_OBS_COUNTER && TENANT_OBS_ENABLED are both on, so when the
// flags are off /metrics is byte-identical. Cardinality is HARD-bounded at
// tenantSeriesCap+1 distinct tenant values per process (see admitTenant).
func (m *Metrics) ObserveTenant(status int, tenantID string) {
	if tenantID == "" || !tenantObsCounterEnabled() {
		return
	}
	label := m.admitTenant(sanitizeTenantLabel(tenantID))
	key := fmt.Sprintf("%dxx", status/100) + "\x00" + label
	ctr, _ := m.tenantReq.LoadOrStore(key, new(int64))
	atomic.AddInt64(ctr.(*int64), 1)
}

// admitTenant returns the label to use for a (sanitized) tenant_id, enforcing
// the hard cap. The atomic CAS on tenantSetSize reserves the slot BEFORE the
// membership is published, so two concurrent first-touches of the SAME new
// tenant consume at most one slot total (the loser's reservation is rolled
// back). Net: tenantSetSize is the exact distinct-admitted count, never > cap.
func (m *Metrics) admitTenant(label string) string {
	if label == overCapSentinel {
		return overCapSentinel // never let a real id masquerade as the sentinel
	}
	if _, ok := m.tenantSet.Load(label); ok {
		return label // already admitted
	}
	for {
		n := atomic.LoadInt64(&m.tenantSetSize)
		if n >= tenantSeriesCap {
			return overCapSentinel
		}
		if atomic.CompareAndSwapInt64(&m.tenantSetSize, n, n+1) {
			if _, loaded := m.tenantSet.LoadOrStore(label, struct{}{}); loaded {
				atomic.AddInt64(&m.tenantSetSize, -1)
			}
			return label
		}
	}
}

// collectTenantRows snapshots the bounded tenant series sorted by (tenant,
// status) for deterministic exposition.
func (m *Metrics) collectTenantRows() []trow {
	var rows []trow
	m.tenantReq.Range(func(k, v any) bool {
		ks := k.(string)
		i := strings.IndexByte(ks, 0)
		rows = append(rows, trow{ks[:i], ks[i+1:], atomic.LoadInt64(v.(*int64))})
		return true
	})
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].tenant != rows[j].tenant {
			return rows[i].tenant < rows[j].tenant
		}
		return rows[i].status < rows[j].status
	})
	return rows
}

// writeTenantSeries emits the BOUNDED per-tenant series on baas_http_requests_total
// (and only this counter, never a histogram). Empty unless both obs flags are on,
// keeping OFF output byte-identical. tenant is already sanitized at Observe time;
// emitted raw inside quotes so escape sequences match the Rust plane byte-for-byte.
func (m *Metrics) writeTenantSeries(w http.ResponseWriter, svc string) {
	if !tenantObsCounterEnabled() {
		return
	}
	for _, r := range m.collectTenantRows() {
		fmt.Fprintf(w, "baas_http_requests_total{service=%q,status=%q,tenant_id=\"%s\"} %d\n",
			svc, r.status, r.tenant, r.n)
	}
}
