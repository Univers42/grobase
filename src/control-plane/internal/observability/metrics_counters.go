package observability

import (
	"fmt"
	"net/http"
	"sort"
	"sync/atomic"
)

// crow is one collected domain-counter row, ready for deterministic emission.
type crow struct {
	id   counterID
	help string
	n    int64
}

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

// collectDomainRows snapshots the custom counters sorted by (name, labelVal) so
// HELP/TYPE print once per name and the exposition is byte-deterministic.
func (m *metrics) collectDomainRows() []crow {
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
	return rows
}

// writeDomainCounters emits the collected domain counters, printing HELP/TYPE
// exactly once per metric name.
func (m *metrics) writeDomainCounters(w http.ResponseWriter, svc string) {
	lastName := ""
	for _, r := range m.collectDomainRows() {
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
