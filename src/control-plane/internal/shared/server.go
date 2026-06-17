package shared

import "net/http"

// NewRouter builds a base mux with liveness/readiness probes and a Prometheus
// /metrics endpoint. The metrics sink is process-global (one binary == one
// service), so no service-specific wiring is needed at the call site.
func NewRouter(service string, db *Postgres) *http.ServeMux {
	procMetrics.setService(service)
	mux := http.NewServeMux()

	mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, _ *http.Request) {
		procMetrics.writeProm(w)
	})
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, _ *http.Request) {
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": service})
	})
	mux.HandleFunc("GET /health/ready", func(w http.ResponseWriter, r *http.Request) {
		if err := db.Ping(r.Context()); err != nil {
			WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "degraded", "error": "db_unreachable"})
			return
		}
		WriteJSON(w, http.StatusOK, map[string]string{"status": "ready", "service": service})
	})
	return mux
}
