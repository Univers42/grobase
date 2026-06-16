package shared

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// procMetrics is the process-wide metrics sink. Each control-plane binary runs
// as its own OS process, so a package-level singleton is naturally scoped to a
// single service — the same pattern client_golang's default registry uses.
//
// Keeping this dependency-free (no client_golang) is deliberate: the control
// plane's value proposition is tiny, fast-starting static binaries, and the
// three daemons only need request counts + a mean-latency gauge to be visible
// to Prometheus. See wiki/05-orchestration-observability-roadmap.md §2 (G7).
var procMetrics = &metrics{start: time.Now()}

// tenantSeriesCap is the HARD in-process ceiling on distinct tenant_id series
// the Pillar-3 bounded counter will track. Past the cap, every further tenant
// folds into a single sentinel series tenant_id="_over_cap", so the exposition
// can never exceed tenantSeriesCap+1 tenant series regardless of how many
// tenants the platform serves (the 10K+-tenant cardinality guard). This MUST
// match the Rust data plane's cap (DATA_PLANE_TENANT_OBS_COUNTER, N=512) so the
// two planes' /metrics agree.
const tenantSeriesCap = 512

// overCapSentinel is the single fold-in label value for tenants beyond the cap.
const overCapSentinel = "_over_cap"

type metrics struct {
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
	tenantReq     sync.Map // key "Nxx\x00<sanitized tenant_id>" -> *int64 (series counters)
	tenantSet     sync.Map // sanitized tenant_id -> struct{} (admitted set; idempotent membership)
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

func (m *metrics) setService(name string) { m.service = name }

// incCounter bumps a domain counter by one, registering its HELP text on first
// touch. Concurrency-safe.
func (m *metrics) incCounter(name, help, labelKey, labelVal string) {
	id := counterID{name, labelKey, labelVal}
	e, _ := m.custom.LoadOrStore(id, &counterEntry{help: help})
	atomic.AddInt64(&e.(*counterEntry).n, 1)
}

// IncCounter bumps a process-wide domain counter (a Prometheus counter) by one.
// `help` is recorded on first registration of `name`; pass "" for labelKey to
// emit an unlabeled counter. Exposed at /metrics next to the HTTP metrics, so
// any control-plane daemon gets domain counters with no extra wiring.
func IncCounter(name, help, labelKey, labelVal string) {
	procMetrics.incCounter(name, help, labelKey, labelVal)
}

// observe records one finished request. method/status come from the middleware.
func (m *metrics) observe(method string, status int, d time.Duration) {
	key := method + ":" + fmt.Sprintf("%dxx", status/100)
	ctr, _ := m.counts.LoadOrStore(key, new(int64))
	atomic.AddInt64(ctr.(*int64), 1)
	atomic.AddInt64(&m.sumNs, d.Nanoseconds())
	atomic.AddInt64(&m.sumCount, 1)
}

// sanitizeTenantLabel mirrors the Rust data plane's escape_label so a tenant_id
// used as a Prometheus label value can never break the exposition or smuggle an
// extra label: backslash, double-quote and newline are escaped. writeProm uses
// %q which already quotes, but %q would render a control character as e.g. \n
// for it ITSELF — sanitizing at the source keeps the two planes' label values
// byte-identical and the cap key stable. Order matches Rust: \ first, then " ,
// then newline.
func sanitizeTenantLabel(v string) string {
	v = strings.ReplaceAll(v, `\`, `\\`)
	v = strings.ReplaceAll(v, `"`, `\"`)
	v = strings.ReplaceAll(v, "\n", `\n`)
	return v
}

// observeTenant is the Pillar-3 (B5) bounded per-tenant request counter. It is a
// NO-OP unless TENANT_OBS_COUNTER && TENANT_OBS_ENABLED are both on, so when the
// flags are off this is never reached and /metrics is byte-identical.
//
// Cardinality is HARD-bounded: the first tenantSeriesCap distinct sanitized
// tenant_ids get their own series; every tenant beyond the cap folds into the
// single overCapSentinel series. Ceiling = (tenantSeriesCap+1) tenant values
// per process, independent of tenant count.
func (m *metrics) observeTenant(status int, tenantID string) {
	if tenantID == "" || !tenantObsCounterEnabled() {
		return
	}
	label := m.admitTenant(sanitizeTenantLabel(tenantID))
	key := fmt.Sprintf("%dxx", status/100) + "\x00" + label
	ctr, _ := m.tenantReq.LoadOrStore(key, new(int64))
	atomic.AddInt64(ctr.(*int64), 1)
}

// admitTenant returns the label to use for a (sanitized) tenant_id, enforcing
// the hard cap. A tenant already in the bounded set keeps its own id; a NEW
// tenant is admitted (and keeps its id) only while there is room, otherwise it
// folds into overCapSentinel. Admission is idempotent per tenant: the atomic CAS
// on tenantSetSize reserves the slot BEFORE the membership is published, so two
// concurrent first-touches of the SAME new tenant can each consume at most one
// slot total (the loser's reservation is rolled back). Net: tenantSetSize is the
// exact count of distinct admitted tenants and never exceeds tenantSeriesCap.
func (m *metrics) admitTenant(label string) string {
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
			// Reserved a slot; publish membership. If a concurrent goroutine
			// published this same label first, release our reservation so the
			// distinct-count stays exact.
			if _, loaded := m.tenantSet.LoadOrStore(label, struct{}{}); loaded {
				atomic.AddInt64(&m.tenantSetSize, -1)
			}
			return label
		}
	}
}

// writeProm emits the Prometheus text exposition format (v0.0.4).
func (m *metrics) writeProm(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	svc := m.service

	fmt.Fprintf(w, "# HELP baas_service_up 1 while the service is serving\n")
	fmt.Fprintf(w, "# TYPE baas_service_up gauge\n")
	fmt.Fprintf(w, "baas_service_up{service=%q} 1\n", svc)

	fmt.Fprintf(w, "# HELP baas_uptime_seconds Seconds since process start\n")
	fmt.Fprintf(w, "# TYPE baas_uptime_seconds gauge\n")
	fmt.Fprintf(w, "baas_uptime_seconds{service=%q} %.0f\n", svc, time.Since(m.start).Seconds())

	fmt.Fprintf(w, "# HELP baas_http_requests_total HTTP requests by method and status class\n")
	fmt.Fprintf(w, "# TYPE baas_http_requests_total counter\n")
	m.counts.Range(func(k, v any) bool {
		parts := strings.SplitN(k.(string), ":", 2)
		fmt.Fprintf(w, "baas_http_requests_total{service=%q,method=%q,status=%q} %d\n",
			svc, parts[0], parts[1], atomic.LoadInt64(v.(*int64)))
		return true
	})
	// Pillar-3 (B5): additionally emit the BOUNDED per-tenant series on the SAME
	// counter (baas_http_requests_total) — and ONLY this counter, NEVER a
	// histogram. Hard-capped at tenantSeriesCap+1 distinct tenant_id values, so
	// this stays cardinality-safe at 10K+ tenants. Empty (never entered) unless
	// TENANT_OBS_COUNTER && TENANT_OBS_ENABLED, keeping OFF output byte-identical.
	// Sorted for deterministic exposition.
	if tenantObsCounterEnabled() {
		type trow struct {
			status, tenant string
			n              int64
		}
		var trows []trow
		m.tenantReq.Range(func(k, v any) bool {
			ks := k.(string)
			i := strings.IndexByte(ks, 0)
			trows = append(trows, trow{ks[:i], ks[i+1:], atomic.LoadInt64(v.(*int64))})
			return true
		})
		sort.Slice(trows, func(i, j int) bool {
			if trows[i].tenant != trows[j].tenant {
				return trows[i].tenant < trows[j].tenant
			}
			return trows[i].status < trows[j].status
		})
		for _, r := range trows {
			// tenant already sanitized at observe time; emit raw inside quotes so
			// the escape sequences match the Rust plane byte-for-byte.
			fmt.Fprintf(w, "baas_http_requests_total{service=%q,status=%q,tenant_id=\"%s\"} %d\n",
				svc, r.status, r.tenant, r.n)
		}
	}

	n := atomic.LoadInt64(&m.sumCount)
	avg := 0.0
	if n > 0 {
		avg = float64(atomic.LoadInt64(&m.sumNs)) / float64(n) / 1e6
	}
	fmt.Fprintf(w, "# HELP baas_http_request_duration_ms_avg Mean request duration in milliseconds\n")
	fmt.Fprintf(w, "# TYPE baas_http_request_duration_ms_avg gauge\n")
	fmt.Fprintf(w, "baas_http_request_duration_ms_avg{service=%q} %.3f\n", svc, avg)

	// Domain counters. Collect + sort so HELP/TYPE print exactly once per metric
	// name and the exposition is byte-deterministic (Prometheus tolerates order,
	// but stable output keeps tests + diffs sane).
	type crow struct {
		id   counterID
		help string
		n    int64
	}
	var rows []crow
	m.custom.Range(func(k, v any) bool {
		e := v.(*counterEntry)
		rows = append(rows, crow{k.(counterID), e.help, atomic.LoadInt64(&e.n)})
		return true
	})
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].id.name != rows[j].id.name {
			return rows[i].id.name < rows[j].id.name
		}
		return rows[i].id.labelVal < rows[j].id.labelVal
	})
	lastName := ""
	for _, r := range rows {
		if r.id.name != lastName {
			fmt.Fprintf(w, "# HELP %s %s\n", r.id.name, r.help)
			fmt.Fprintf(w, "# TYPE %s counter\n", r.id.name)
			lastName = r.id.name
		}
		if r.id.labelKey != "" {
			fmt.Fprintf(w, "%s{service=%q,%s=%q} %d\n", r.id.name, svc, r.id.labelKey, r.id.labelVal, r.n)
		} else {
			fmt.Fprintf(w, "%s{service=%q} %d\n", r.id.name, svc, r.n)
		}
	}
}
