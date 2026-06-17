package spendcap

import (
	"fmt"
	"sort"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
)

// rateTable maps a B1 usage metric → its price in MILLI-cents per unit
// (cents×1000), so a fractional per-unit price (e.g. 0.002¢ / query) is an
// integer and money math never touches float. Spend in cents = Σ(qty × milliRate)
// / 1000. Loaded from env SPEND_RATE_<METRIC> (a decimal cents-per-unit string,
// e.g. "0.0001"), so $-pricing is per-deployment, never in packages.json.
type rateTable struct {
	milliPerUnit map[string]int64 // metric → milli-cents per unit
}

// loadRateTable reads the SPEND_RATE_* env into a metric→milli-cents map. Only
// metrics with a positive rate are included (opt-in per dimension); an unparsable
// or non-positive rate is skipped (it would price that dimension at zero anyway).
func loadRateTable() rateTable {
	metrics := billableMetrics()
	m := make(map[string]int64, len(metrics))
	for _, metric := range metrics {
		raw := strings.TrimSpace(config.EnvStr(billableMetricEnv(metric), ""))
		if raw == "" {
			continue
		}
		// cents-per-unit decimal → milli-cents integer (×1000), rounded.
		if cents, ok := parseCentsToMilli(raw); ok && cents > 0 {
			m[metric] = cents
		}
	}
	return rateTable{milliPerUnit: m}
}

// parseCentsToMilli converts a decimal cents string ("0.0001") to milli-cents
// (cents×1000) as an integer, rounding to the nearest milli-cent. Returns false on
// a malformed value so a typo cannot silently price a dimension wrong.
func parseCentsToMilli(s string) (int64, bool) {
	var f float64
	if _, err := fmt.Sscanf(s, "%g", &f); err != nil || f < 0 {
		return 0, false
	}
	// +0.5 for round-to-nearest on the positive domain.
	return int64(f*1000 + 0.5), true
}

func (t rateTable) empty() bool { return len(t.milliPerUnit) == 0 }

// metrics returns the priced metric names, sorted for a stable `= ANY($1)` SQL
// argument and deterministic logging.
func (t rateTable) metrics() []string {
	out := make([]string, 0, len(t.milliPerUnit))
	for k := range t.milliPerUnit {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// spendCentsFor converts a per-metric usage map to spend in whole cents using the
// rate table. Integer math throughout: Σ(qty × milliRate) accumulated in
// milli-cents, divided by 1000 at the end. A metric with no rate contributes 0.
func (t rateTable) spendCentsFor(usageByMetric map[string]int64) int64 {
	var milli int64
	for metric, qty := range usageByMetric {
		if r, ok := t.milliPerUnit[metric]; ok && qty > 0 {
			milli += qty * r
		}
	}
	return milli / 1000
}
