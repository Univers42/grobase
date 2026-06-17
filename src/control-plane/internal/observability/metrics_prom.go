package observability

import (
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

// writeProm emits the Prometheus text exposition format (v0.0.4).
func (m *metrics) writeProm(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	svc := m.service
	m.writeServiceGauges(w, svc)
	m.writeHTTPCounts(w, svc)
	m.writeTenantSeries(w, svc)
	m.writeDurationAvg(w, svc)
	m.writeDomainCounters(w, svc)
}

// writeServiceGauges emits the up + uptime gauges.
func (m *metrics) writeServiceGauges(w http.ResponseWriter, svc string) {
	fmt.Fprintf(w, "# HELP baas_service_up 1 while the service is serving\n")
	fmt.Fprintf(w, "# TYPE baas_service_up gauge\n")
	fmt.Fprintf(w, "baas_service_up{service=%q} 1\n", svc)
	fmt.Fprintf(w, "# HELP baas_uptime_seconds Seconds since process start\n")
	fmt.Fprintf(w, "# TYPE baas_uptime_seconds gauge\n")
	fmt.Fprintf(w, "baas_uptime_seconds{service=%q} %.0f\n", svc, time.Since(m.start).Seconds())
}

// writeHTTPCounts emits baas_http_requests_total by method and status class.
func (m *metrics) writeHTTPCounts(w http.ResponseWriter, svc string) {
	fmt.Fprintf(w, "# HELP baas_http_requests_total HTTP requests by method and status class\n")
	fmt.Fprintf(w, "# TYPE baas_http_requests_total counter\n")
	m.counts.Range(func(k, v any) bool {
		parts := strings.SplitN(k.(string), ":", 2)
		fmt.Fprintf(w, "baas_http_requests_total{service=%q,method=%q,status=%q} %d\n",
			svc, parts[0], parts[1], atomic.LoadInt64(v.(*int64)))
		return true
	})
}

// writeDurationAvg emits the mean request-duration gauge in milliseconds.
func (m *metrics) writeDurationAvg(w http.ResponseWriter, svc string) {
	n := atomic.LoadInt64(&m.sumCount)
	avg := 0.0
	if n > 0 {
		avg = float64(atomic.LoadInt64(&m.sumNs)) / float64(n) / 1e6
	}
	fmt.Fprintf(w, "# HELP baas_http_request_duration_ms_avg Mean request duration in milliseconds\n")
	fmt.Fprintf(w, "# TYPE baas_http_request_duration_ms_avg gauge\n")
	fmt.Fprintf(w, "baas_http_request_duration_ms_avg{service=%q} %.3f\n", svc, avg)
}
