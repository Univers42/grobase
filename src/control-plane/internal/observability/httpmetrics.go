package observability

import (
	"net/http"
	"time"
)

// SetService records the service name used as the `service` label on every
// exported metric. Called once at router construction.
func SetService(name string) { procMetrics.setService(name) }

// WriteProm writes the Prometheus text exposition to w (the /metrics handler).
func WriteProm(w http.ResponseWriter) { procMetrics.writeProm(w) }

// Observe records one finished request (method, status class, duration).
func Observe(method string, status int, d time.Duration) {
	procMetrics.observe(method, status, d)
}

// ObserveTenant records one finished request against the bounded per-tenant
// series (a no-op unless the tenant-obs flags are on).
func ObserveTenant(status int, tenantID string) {
	procMetrics.observeTenant(status, tenantID)
}
