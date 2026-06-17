package packages

// clampMaxRows clamps the optional rows-per-query cap. A nil custom inherits the
// ceiling; a nil ceiling is "unlimited" so any present custom is the bound; both
// present → min.
func clampMaxRows(custom, ceiling *uint32) *uint32 {
	if custom == nil {
		return ceiling
	}
	if ceiling == nil {
		v := *custom
		return &v
	}
	v := *custom
	if v > *ceiling {
		v = *ceiling
	}
	return &v
}

// clampQuota clamps the optional cumulative quota. A nil custom inherits the
// ceiling; a nil ceiling is "unlimited" so any present custom is the bound; both
// present → min(query.count), period taken from the ceiling (the catalog period
// is a single source — a custom cannot widen the window).
func clampQuota(custom, ceiling *Quota) *Quota {
	if custom == nil {
		return ceiling
	}
	period := custom.Period
	count := custom.QueryCount
	if ceiling == nil {
		return &Quota{Period: period, QueryCount: count}
	}
	if period == "" {
		period = ceiling.Period
	} else {
		period = ceiling.Period // the catalog period is authoritative; never widen the window
	}
	if ceiling.QueryCount != 0 && (count == 0 || count > ceiling.QueryCount) {
		count = ceiling.QueryCount
	}
	return &Quota{Period: period, QueryCount: count}
}
