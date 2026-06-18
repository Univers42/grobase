// Package packages loads the BaaS service-tier manifest (Phase 4 tiering).
//
// The canonical manifest lives at config/packages/packages.json; a byte-
// identical copy is embedded here so the control-plane binary needs no mounted
// file at runtime (m28 asserts the two stay in sync). A tier defines:
//
//   - engines:      which engines a tenant on this package may register a mount for
//   - capabilities: a NARROWING capability mask the data plane intersects with
//     the engine descriptor (a false flag removes a capability; the Rust planner
//     can never widen past the engine — see apply_capability_overrides)
//   - limits:       rps/burst for the per-tenant token bucket
//   - pool_policy:  max_conn (pool size hint) + max_mounts (registration cap)
//   - addons:       à-la-carte planes the tenant is entitled to
//
// A tenant's package is its `plan` column (the existing tenants.plan); an
// unknown/empty plan degrades to the manifest's default_package.
package packages

import (
	_ "embed"
	"encoding/json"
	"fmt"
)

//go:embed packages.json
var embedded []byte

// Limits is the per-tenant request-rate budget fed to the data plane's token
// bucket.
type Limits struct {
	RPS   uint32 `json:"rps"`
	Burst uint32 `json:"burst"`
	// MaxRows (G-QoS sliceA) is the optional rows-per-query cap the data plane
	// clamps `operation.limit` to (engine-agnostic). A nil pointer / omitted key
	// means "unlimited" — the parity path that leaves the limit untouched. Only
	// stamped onto capability_overrides when present, so absent tiers behave
	// exactly as today.
	MaxRows *uint32 `json:"max_rows,omitempty"`
	// Quota (Track-B B2) is the optional CUMULATIVE per-period usage cap the
	// control-plane QuotaGuard enforces against public.tenant_usage (B1). A nil
	// pointer / omitted key means "unlimited" — the byte-parity pre-B2 path (no
	// tenant is ever over quota). Distinct from rps/burst (per-request rate, m51)
	// and max_rows (per-query rows, A6): quota is the period-cumulative budget.
	Quota *Quota `json:"quota,omitempty"`
}

// Quota is one tier's cumulative usage budget per rolling period (Track-B B2).
// The QuotaGuard sums public.tenant_usage for the metered metric over the
// current period and rejects (via the data plane, 402) a tenant whose summed
// qty exceeds the cap. ONLY the dimensions packages.json actually caps are
// enforced; a zero/absent cap on a metric is "unlimited" for that metric.
type Quota struct {
	// Period is the rolling window the cap applies to: "month" (default),
	// "day", or "hour". The QuotaGuard derives the window start from this.
	Period string `json:"period"`
	// QueryCount caps metered read-requests (B1 `query.count`) per period. 0 /
	// omitted = unlimited for this metric. This is the dimension packages.json
	// caps today; adding storage.bytes / function.invocations is one field each.
	QueryCount uint64 `json:"query.count,omitempty"`
}

// PoolPolicy bounds a tenant's footprint: connection-pool size + how many
// database mounts it may register.
type PoolPolicy struct {
	MaxConn   int `json:"max_conn"`
	MaxMounts int `json:"max_mounts"`
}

// Package is one service tier.
type Package struct {
	Label        string          `json:"label"`
	Engines      []string        `json:"engines"`
	Capabilities map[string]bool `json:"capabilities"`
	Limits       Limits          `json:"limits"`
	PoolPolicy   PoolPolicy      `json:"pool_policy"`
	SecurityMode string          `json:"security_mode"`
	Addons       []string        `json:"addons"`
}

// Addon maps an à-la-carte feature name to its compose plane.
type Addon struct {
	Plane string `json:"plane"`
	Label string `json:"label"`
}

// Manifest is the whole tier catalog.
type Manifest struct {
	Version        int    `json:"version"`
	DefaultPackage string `json:"default_package"`
	// Aliases maps legacy tenants.plan values (free/pro/enterprise — the live
	// CHECK constraint) onto tier names, so tiering needs no destructive plan
	// migration: free→essential, enterprise→max.
	Aliases  map[string]string  `json:"aliases"`
	Packages map[string]Package `json:"packages"`
	Addons   map[string]Addon   `json:"addons"`
}

// Load parses the embedded manifest once at startup. A malformed manifest is a
// hard error — tiering is a security boundary, so we fail fast rather than serve
// an empty (deny-all or allow-all) catalog.
func Load() (*Manifest, error) {
	var m Manifest
	if err := json.Unmarshal(embedded, &m); err != nil {
		return nil, fmt.Errorf("parse embedded packages manifest: %w", err)
	}
	if len(m.Packages) == 0 {
		return nil, fmt.Errorf("packages manifest has no packages")
	}
	if _, ok := m.Packages[m.DefaultPackage]; !ok {
		return nil, fmt.Errorf("default_package %q not in manifest", m.DefaultPackage)
	}
	return &m, nil
}

// For resolves a tenant's plan name to its package: a direct package key wins,
// else a legacy-plan alias (free/enterprise), else the default package (so a
// tenant created before tiering, or with a stale/unknown plan, gets the safe
// baseline tier rather than an error). Returns the resolved package NAME +
// the package.
func (m *Manifest) For(plan string) (string, Package) {
	if p, ok := m.Packages[plan]; ok {
		return plan, p
	}
	if alias, ok := m.Aliases[plan]; ok {
		if p, ok := m.Packages[alias]; ok {
			return alias, p
		}
	}
	return m.DefaultPackage, m.Packages[m.DefaultPackage]
}

// AllowsEngine reports whether this package may register a mount for `engine`.
func (p Package) AllowsEngine(engine string) bool {
	for _, e := range p.Engines {
		if e == engine {
			return true
		}
	}
	return false
}
