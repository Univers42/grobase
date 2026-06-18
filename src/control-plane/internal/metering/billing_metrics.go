package metering

// billableMetrics is the closed set of meterable dimensions, from B1's frozen
// metric vocabulary (see store.go fieldMetric). Returned from a func (not a
// package var) so the package declares no global.
func billableMetrics() []string {
	return []string{
		"query.count", "query.rows", "write.rows",
		"storage.bytes", "realtime.minutes", "function.invocations",
	}
}

// billableMetricEnv maps a billable dimension → the env var carrying its Stripe
// event_name. Extending billing to a new dimension is one case here + the metric
// in billableMetrics + the env in the deployment. Unknown → "".
func billableMetricEnv(metric string) string {
	switch metric {
	case "query.count":
		return "BILLING_METER_QUERY_COUNT"
	case "query.rows":
		return "BILLING_METER_QUERY_ROWS"
	case "write.rows":
		return "BILLING_METER_WRITE_ROWS"
	case "storage.bytes":
		return "BILLING_METER_STORAGE_BYTES"
	case "realtime.minutes":
		return "BILLING_METER_REALTIME_MINUTES"
	case "function.invocations":
		return "BILLING_METER_FUNCTION_INVOCATIONS"
	}
	return ""
}
