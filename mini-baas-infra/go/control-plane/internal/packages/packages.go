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
	"sort"
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

// ─── Dynamic builder (BUILDER_ENABLED): Clamp + ValidateWithin ──────────────
//
// The dynamic builder lets a tenant COMPOSE its own effective package (narrowed
// capabilities, fewer mounts, a lower rps, a subset of engines, …) and lets an
// operator MINT a custom entitlement, all WITHIN a CEILING (the paid tier or an
// operator-set ceiling_plan). The ceiling is a PRIVILEGE BOUNDARY: a tenant may
// never grant itself MORE than the ceiling allows.
//
// Two pure functions enforce that boundary at two distinct points:
//
//   - ValidateWithin(custom, ceiling) — COMPOSE-time check. Returns a clean
//     error naming the FIRST axis a custom entitlement exceeds the ceiling, so a
//     PATCH /me/entitlements can refuse with a 403 BEFORE persisting. It is the
//     friendly gate.
//   - Clamp(custom, ceiling) — RESOLVE-time BACKSTOP. ALWAYS returns a package
//     that is ≤ the ceiling on every axis, silently lowering any field that
//     exceeds it. It NEVER trusts the stored row: a row written over the ceiling
//     (e.g. an operator set it high, then the tenant was downgraded) is clamped
//     on every single resolve. Clamp is the load-bearing one — even if
//     ValidateWithin were skipped, Clamp guarantees the stamp never exceeds the
//     ceiling.
//
// Clamp semantics (each axis, the ceiling is the cap):
//   - Label:        taken from custom if set, else the ceiling's (cosmetic).
//   - Engines:      custom ∩ ceiling (a custom engine not in the ceiling is
//     dropped — never added).
//   - Capabilities: a capability may be turned OFF freely, but turning it ON is
//     only honored when the ceiling also has it ON (false ceiling clamps to
//     false). Capabilities ABSENT from custom inherit the ceiling's value.
//   - rps/burst/max_rows/quota.query.count: min(custom, ceiling); a custom value
//     of 0/absent means "inherit the ceiling" (NOT "unlimited"), so a tenant can
//     never widen an unset field past the cap.
//   - max_conn/max_mounts: min(custom, ceiling), same inherit-on-0 rule.
//   - Addons:       custom ∩ ceiling.
//   - SecurityMode: only ALLOWED to become STRICTER (baseline→max). A custom
//     attempt to LOOSEN max→baseline is clamped back to the ceiling's mode.

// securityRank ranks security_mode from loosest to strictest. A higher rank is
// stricter. Unknown modes rank as baseline (the safe floor) so a typo never
// silently loosens enforcement.
func securityRank(mode string) int {
	switch mode {
	case "max":
		return 1
	default: // "baseline" / "" / unknown
		return 0
	}
}

// Clamp returns an EFFECTIVE package that is ≤ ceiling on every axis. It is the
// resolve-time backstop: a custom entitlement is overlaid onto the ceiling but
// can only ever NARROW, never widen. See the block comment above for per-axis
// semantics. Pure (no I/O); the ceiling is treated as immutable.
func Clamp(custom, ceiling Package) Package {
	out := Package{
		Label:        ceiling.Label,
		Capabilities: make(map[string]bool, len(ceiling.Capabilities)),
		Limits:       ceiling.Limits, // start from ceiling, then lower per-field
		PoolPolicy:   ceiling.PoolPolicy,
		SecurityMode: ceiling.SecurityMode,
	}
	if custom.Label != "" {
		out.Label = custom.Label
	}

	// Engines: custom ∩ ceiling. An empty custom engine list inherits the
	// ceiling's engines (no narrowing requested), so an entitlement that only
	// caps rps does not accidentally strip every engine.
	if len(custom.Engines) == 0 {
		out.Engines = append([]string(nil), ceiling.Engines...)
	} else {
		allowed := make(map[string]bool, len(ceiling.Engines))
		for _, e := range ceiling.Engines {
			allowed[e] = true
		}
		for _, e := range custom.Engines {
			if allowed[e] {
				out.Engines = append(out.Engines, e)
			}
		}
	}

	// Capabilities: start from the ceiling, then apply custom — true only honored
	// when the ceiling is also true (clamp ON→OFF when over ceiling); OFF always
	// honored. Capabilities absent from custom keep the ceiling's value.
	for k, v := range ceiling.Capabilities {
		out.Capabilities[k] = v
	}
	for k, v := range custom.Capabilities {
		ceil := ceiling.Capabilities[k]
		out.Capabilities[k] = v && ceil // can turn OFF freely, never ON past ceiling
	}

	// Limits: min(custom, ceiling) with inherit-on-0. A custom 0/absent means
	// "inherit the ceiling" — NEVER "unlimited" — so an unset field can never
	// widen the cap.
	out.Limits.RPS = clampU32(custom.Limits.RPS, ceiling.Limits.RPS)
	out.Limits.Burst = clampU32(custom.Limits.Burst, ceiling.Limits.Burst)
	out.Limits.MaxRows = clampMaxRows(custom.Limits.MaxRows, ceiling.Limits.MaxRows)
	out.Limits.Quota = clampQuota(custom.Limits.Quota, ceiling.Limits.Quota)

	// PoolPolicy: min(custom, ceiling), inherit-on-0.
	out.PoolPolicy.MaxConn = clampInt(custom.PoolPolicy.MaxConn, ceiling.PoolPolicy.MaxConn)
	out.PoolPolicy.MaxMounts = clampInt(custom.PoolPolicy.MaxMounts, ceiling.PoolPolicy.MaxMounts)

	// Addons: custom ∩ ceiling. Empty custom inherits the ceiling's addons.
	if len(custom.Addons) == 0 {
		out.Addons = append([]string(nil), ceiling.Addons...)
	} else {
		allowed := make(map[string]bool, len(ceiling.Addons))
		for _, a := range ceiling.Addons {
			allowed[a] = true
		}
		for _, a := range custom.Addons {
			if allowed[a] {
				out.Addons = append(out.Addons, a)
			}
		}
	}

	// SecurityMode: only allowed to become STRICTER. A custom mode that is ≥ the
	// ceiling's rank is honored; a looser custom mode is clamped to the ceiling.
	if custom.SecurityMode != "" && securityRank(custom.SecurityMode) >= securityRank(ceiling.SecurityMode) {
		out.SecurityMode = custom.SecurityMode
	}

	return out
}

// clampU32 returns min(custom, ceiling) treating a custom 0 as "inherit ceiling"
// and a ceiling 0 as "unlimited" (so an unbounded ceiling field stays unbounded).
func clampU32(custom, ceiling uint32) uint32 {
	if custom == 0 {
		return ceiling
	}
	if ceiling == 0 { // ceiling unlimited → custom is the (lower) bound
		return custom
	}
	if custom > ceiling {
		return ceiling
	}
	return custom
}

// clampInt is clampU32 for the int pool-policy fields.
func clampInt(custom, ceiling int) int {
	if custom <= 0 {
		return ceiling
	}
	if ceiling <= 0 {
		return custom
	}
	if custom > ceiling {
		return ceiling
	}
	return custom
}

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

// ValidateWithin reports the FIRST axis on which custom exceeds ceiling, as a
// clean error a compose-time handler maps to 403 entitlement_exceeds_ceiling. It
// is the friendly pre-write gate; Clamp is the resolve-time backstop. Pure.
//
// "Exceeds" means: an engine not in the ceiling; a capability turned ON the
// ceiling has OFF; an rps/burst/max_rows/quota above the ceiling's positive cap;
// max_conn/max_mounts above the ceiling's positive cap; an addon not in the
// ceiling; a security_mode LOOSER than the ceiling. Turning things OFF/down is
// always within bounds (returns nil).
func ValidateWithin(custom, ceiling Package) error {
	ceilEngines := make(map[string]bool, len(ceiling.Engines))
	for _, e := range ceiling.Engines {
		ceilEngines[e] = true
	}
	for _, e := range sortedStrings(custom.Engines) {
		if !ceilEngines[e] {
			return fmt.Errorf("engine %q exceeds ceiling (ceiling engines: %v)", e, ceiling.Engines)
		}
	}

	for _, k := range sortedCapKeys(custom.Capabilities) {
		if custom.Capabilities[k] && !ceiling.Capabilities[k] {
			return fmt.Errorf("capability %q exceeds ceiling (ceiling has it off)", k)
		}
	}

	if over := overU32("rps", custom.Limits.RPS, ceiling.Limits.RPS); over != nil {
		return over
	}
	if over := overU32("burst", custom.Limits.Burst, ceiling.Limits.Burst); over != nil {
		return over
	}
	if custom.Limits.MaxRows != nil && ceiling.Limits.MaxRows != nil && *custom.Limits.MaxRows > *ceiling.Limits.MaxRows {
		return fmt.Errorf("max_rows %d exceeds ceiling %d", *custom.Limits.MaxRows, *ceiling.Limits.MaxRows)
	}
	if custom.Limits.Quota != nil && ceiling.Limits.Quota != nil &&
		ceiling.Limits.Quota.QueryCount != 0 && custom.Limits.Quota.QueryCount > ceiling.Limits.Quota.QueryCount {
		return fmt.Errorf("quota.query.count %d exceeds ceiling %d",
			custom.Limits.Quota.QueryCount, ceiling.Limits.Quota.QueryCount)
	}

	if over := overInt("max_conn", custom.PoolPolicy.MaxConn, ceiling.PoolPolicy.MaxConn); over != nil {
		return over
	}
	if over := overInt("max_mounts", custom.PoolPolicy.MaxMounts, ceiling.PoolPolicy.MaxMounts); over != nil {
		return over
	}

	ceilAddons := make(map[string]bool, len(ceiling.Addons))
	for _, a := range ceiling.Addons {
		ceilAddons[a] = true
	}
	for _, a := range sortedStrings(custom.Addons) {
		if !ceilAddons[a] {
			return fmt.Errorf("addon %q exceeds ceiling (ceiling addons: %v)", a, ceiling.Addons)
		}
	}

	if custom.SecurityMode != "" && securityRank(custom.SecurityMode) < securityRank(ceiling.SecurityMode) {
		return fmt.Errorf("security_mode %q is looser than ceiling %q", custom.SecurityMode, ceiling.SecurityMode)
	}
	return nil
}

// overU32 returns an error iff custom exceeds a POSITIVE ceiling (a ceiling of 0
// is "unlimited", so nothing exceeds it). A custom 0 (inherit) never exceeds.
func overU32(field string, custom, ceiling uint32) error {
	if ceiling != 0 && custom > ceiling {
		return fmt.Errorf("%s %d exceeds ceiling %d", field, custom, ceiling)
	}
	return nil
}

// overInt is overU32 for the int pool-policy fields.
func overInt(field string, custom, ceiling int) error {
	if ceiling > 0 && custom > ceiling {
		return fmt.Errorf("%s %d exceeds ceiling %d", field, custom, ceiling)
	}
	return nil
}

// sortedStrings returns a sorted copy so ValidateWithin reports a DETERMINISTIC
// first-offending axis (map/slice iteration order would make the error message
// flaky across runs and across the two enforcement points).
func sortedStrings(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

// sortedCapKeys returns the capability keys sorted, for the same determinism.
func sortedCapKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
