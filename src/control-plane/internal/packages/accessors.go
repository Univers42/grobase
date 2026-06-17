package packages

// QueryCountCap returns the per-period query.count cap and whether it is set
// (a positive cap). A nil Quota or a zero cap means "unlimited" (parity).
func (p Package) QueryCountCap() (uint64, bool) {
	if p.Limits.Quota == nil || p.Limits.Quota.QueryCount == 0 {
		return 0, false
	}
	return p.Limits.Quota.QueryCount, true
}

// QuotaPeriod returns the configured period, defaulting to "month".
func (p Package) QuotaPeriod() string {
	if p.Limits.Quota == nil || p.Limits.Quota.Period == "" {
		return "month"
	}
	return p.Limits.Quota.Period
}

// CapabilityOverrides is the tier mask the data plane consumes: the capability
// bools MERGED with the rps/burst limits into one object, matching exactly what
// the Rust planner (apply_capability_overrides) and rate limiter (tier_rate)
// read off DatabaseMount.capability_overrides. Returned as the JSON the
// query-router stamps onto the mount it forwards to Rust.
func (p Package) CapabilityOverrides() map[string]any {
	out := make(map[string]any, len(p.Capabilities)+2)
	for k, v := range p.Capabilities {
		out[k] = v
	}
	out["rps"] = p.Limits.RPS
	out["burst"] = p.Limits.Burst
	// G-QoS sliceA: only carry max_rows when the tier sets it, so tiers without
	// a cap produce byte-identical overrides to today (Rust treats absent =
	// unlimited).
	if p.Limits.MaxRows != nil {
		out["max_rows"] = *p.Limits.MaxRows
	}
	return out
}
